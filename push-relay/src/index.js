// MeshHome push relay: a Cloudflare Worker that forwards encrypted notifications from MeshHome
// servers to Apple's push service (APNs). See README.md.
//
// Only the relay holds the app's APNs key. It stores nothing and never sees message content:
// MeshHome encrypts each notification for the phone, which decrypts it. A server can only push to
// a phone that gave it a ticket, and the phone gets its ticket from the relay (POST /v1/register).
//
// Secrets (wrangler secret put …): APNS_KEY (the .p8 file's contents), APNS_KEY_ID, APNS_TEAM_ID,
// TICKET_SECRET (random, at least 32 bytes). Vars (wrangler.toml): BUNDLE_ID.

const MAX_PAYLOAD = 3000; // base64 characters; APNs allows 4 KB in total
const TOKEN_RE = /^[0-9a-f]{32,200}$/;
const TICKET_RE = /^[A-Za-z0-9_-]{20,128}$/;
const COLLAPSE_RE = /^[0-9a-f]{1,64}$/;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const ENVIRONMENTS = { production: "https://api.push.apple.com", development: "https://api.sandbox.push.apple.com" };
const JWT_LIFETIME = 50 * 60; // APNs accepts a provider token for up to an hour
const GONE_REASONS = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "ExpiredToken"]);

const enc = new TextEncoder();

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function b64url(bytes) {
  const b = typeof bytes === "string" ? enc.encode(bytes) : new Uint8Array(bytes);
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s) {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

function pemToDer(pem) {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

async function readJson(request) {
  const text = await request.text();
  if (text.length > 8192) throw new HttpError(413, "request too large");
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

function check(cond, message) {
  if (!cond) throw new HttpError(400, message);
}

async function limited(binding, key) {
  // Cloudflare's rate limiting binding (wrangler.toml); absent in local tests.
  if (!binding) return false;
  const { success } = await binding.limit({ key });
  return !success;
}

// ---- tickets: HMAC(TICKET_SECRET, "platform:environment:token") ----------------------------

async function ticketKey(env) {
  if (!env.TICKET_SECRET || env.TICKET_SECRET.length < 32) throw new HttpError(503, "relay not configured");
  return crypto.subtle.importKey("raw", enc.encode(env.TICKET_SECRET), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

function ticketData(platform, environment, token) {
  return enc.encode(`${platform}:${environment}:${token}`);
}

async function register(request, env) {
  const { platform, environment, token } = await readJson(request);
  check(platform === "ios", "unsupported platform");
  check(environment in ENVIRONMENTS, "unknown environment");
  check(typeof token === "string" && TOKEN_RE.test(token), "invalid token");
  if (await limited(env.REGISTER_LIMIT, request.headers.get("cf-connecting-ip") || "unknown")) {
    throw new HttpError(429, "too many requests");
  }
  const sig = await crypto.subtle.sign("HMAC", await ticketKey(env), ticketData(platform, environment, token));
  return json({ ticket: b64url(sig) });
}

// ---- APNs ------------------------------------------------------------------------------------

let cachedJwt = null;

async function apnsJwt(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.keyId === env.APNS_KEY_ID && now - cachedJwt.iat < JWT_LIFETIME) return cachedJwt.token;
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) throw new HttpError(503, "relay not configured");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(env.APNS_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  cachedJwt = { token: `${header}.${claims}.${b64url(sig)}`, iat: now, keyId: env.APNS_KEY_ID };
  return cachedJwt.token;
}

async function push(request, env) {
  const { platform, environment, token, ticket, payload, collapse_id: collapseId } = await readJson(request);
  check(platform === "ios", "unsupported platform");
  check(environment in ENVIRONMENTS, "unknown environment");
  check(typeof token === "string" && TOKEN_RE.test(token), "invalid token");
  check(typeof ticket === "string" && TICKET_RE.test(ticket), "invalid ticket");
  check(typeof payload === "string" && payload.length <= MAX_PAYLOAD && B64_RE.test(payload), "invalid payload");
  check(collapseId === undefined || (typeof collapseId === "string" && COLLAPSE_RE.test(collapseId)), "invalid collapse_id");

  // crypto.subtle.verify compares in constant time.
  const ok = await crypto.subtle.verify(
    "HMAC",
    await ticketKey(env),
    b64urlDecode(ticket),
    ticketData(platform, environment, token),
  );
  if (!ok) throw new HttpError(403, "ticket does not match this device");
  if (await limited(env.PUSH_LIMIT, token)) throw new HttpError(429, "too many notifications for this device");

  const headers = {
    authorization: `bearer ${await apnsJwt(env)}`,
    "apns-topic": env.BUNDLE_ID,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 24 * 3600),
  };
  if (collapseId) headers["apns-collapse-id"] = collapseId;
  // The app's notification extension replaces this text with the decrypted sender and message.
  const body = {
    aps: { alert: { title: "MeshHome", body: "New message" }, "mutable-content": 1, sound: "default" },
    p: payload,
  };
  const base = env.APNS_HOST_OVERRIDE || ENVIRONMENTS[environment]; // override: tests only
  const res = await fetch(`${base}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(body) });
  if (res.status === 200) return json({ ok: true });

  let reason = "";
  try {
    reason = (await res.json()).reason || "";
  } catch {
    // no body
  }
  if (res.status === 410 || GONE_REASONS.has(reason)) return json({ error: "device unregistered" }, 410);
  if (res.status === 429) return json({ error: "Apple is throttling this device" }, 429);
  if (res.status === 403) {
    cachedJwt = null;
    return json({ error: `relay credentials rejected by Apple (${reason})` }, 502);
  }
  return json({ error: `Apple answered ${res.status}${reason ? ` (${reason})` : ""}` }, 502);
}

function paused(env) {
  return ["1", "true", "yes"].includes(String(env.PAUSED || "").trim().toLowerCase());
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    try {
      if (request.method === "GET" && pathname === "/health") return json({ ok: true, paused: paused(env) });
      // The owner's switch (Cloudflare dashboard → this Worker → Settings → Variables: PAUSED = 1).
      if (paused(env) && pathname.startsWith("/v1/")) return json({ error: "push notifications are paused" }, 503);
      if (request.method === "POST" && pathname === "/v1/register") return await register(request, env);
      if (request.method === "POST" && pathname === "/v1/push") return await push(request, env);
      return json({ error: "not found" }, 404);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error("relay error:", e && e.name); // never log payloads or tokens
      return json({ error: "relay error" }, 500);
    }
  },
};

export const _test = { resetJwt: () => (cachedJwt = null) };
