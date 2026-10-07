// Run with: node --test   (Node 20+; no dependencies)
import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import worker, { _test } from "../src/index.js";

const TOKEN = "ab".repeat(32);
let sent = [];
let apnsAnswer = { status: 200, body: "" };
let publicKey;

async function makeEnv() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  publicKey = pair.publicKey;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----\n`;
  return {
    APNS_KEY: pem,
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: "TEAMID1234",
    TICKET_SECRET: "x".repeat(40),
    BUNDLE_ID: "app.example",
  };
}

let env;
beforeEach(async () => {
  env = await makeEnv();
  _test.resetJwt();
  sent = [];
  apnsAnswer = { status: 200, body: "" };
  globalThis.fetch = async (url, init) => {
    sent.push({ url, init });
    return new Response(apnsAnswer.body, { status: apnsAnswer.status });
  };
});

function call(path, body, method = "POST") {
  return worker.fetch(
    new Request(`https://relay.test${path}`, { method, body: body === undefined ? undefined : JSON.stringify(body) }),
    env,
  );
}

async function ticket(environment = "development", token = TOKEN) {
  const r = await call("/v1/register", { platform: "ios", environment, token });
  assert.equal(r.status, 200);
  return (await r.json()).ticket;
}

const payload = btoa("ciphertext-only");

test("health", async () => {
  assert.equal((await call("/health", undefined, "GET")).status, 200);
});

test("register validates input", async () => {
  assert.equal((await call("/v1/register", { platform: "android", environment: "production", token: TOKEN })).status, 400);
  assert.equal((await call("/v1/register", { platform: "ios", environment: "production", token: "nothex" })).status, 400);
  assert.equal((await call("/v1/register", { platform: "ios", environment: "staging", token: TOKEN })).status, 400);
});

test("push with a valid ticket reaches APNs, signed and opaque", async () => {
  const t = await ticket();
  const r = await call("/v1/push", {
    platform: "ios", environment: "development", token: TOKEN, ticket: t, payload, collapse_id: "abc123",
  });
  assert.equal(r.status, 200);
  assert.equal(sent.length, 1);
  const { url, init } = sent[0];
  assert.equal(url, `https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
  assert.equal(init.headers["apns-topic"], "app.example");
  assert.equal(init.headers["apns-push-type"], "alert");
  assert.equal(init.headers["apns-collapse-id"], "abc123");
  const body = JSON.parse(init.body);
  assert.equal(body.p, payload);
  assert.equal(body.aps["mutable-content"], 1);
  // The provider token is an ES256 JWT that verifies with the key's public half.
  const [h, c, s] = init.headers.authorization.replace("bearer ", "").split(".");
  const dec = (x) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
  assert.deepEqual(dec(h), { alg: "ES256", kid: "KEYID12345" });
  assert.equal(dec(c).iss, "TEAMID1234");
  const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - (s.length % 4)) % 4)), (x) => x.charCodeAt(0));
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, sig, new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok, "JWT signature verifies");
});

test("production goes to the production host", async () => {
  const t = await ticket("production");
  await call("/v1/push", { platform: "ios", environment: "production", token: TOKEN, ticket: t, payload });
  assert.equal(sent[0].url, `https://api.push.apple.com/3/device/${TOKEN}`);
});

test("a ticket only works for its own device and environment", async () => {
  const t = await ticket("development");
  const other = "cd".repeat(32);
  assert.equal((await call("/v1/push", { platform: "ios", environment: "development", token: other, ticket: t, payload })).status, 403);
  assert.equal((await call("/v1/push", { platform: "ios", environment: "production", token: TOKEN, ticket: t, payload })).status, 403);
  assert.equal((await call("/v1/push", { platform: "ios", environment: "development", token: TOKEN, ticket: "A".repeat(43), payload })).status, 403);
  assert.equal(sent.length, 0);
});

test("payload and collapse id are checked", async () => {
  const t = await ticket();
  const base = { platform: "ios", environment: "development", token: TOKEN, ticket: t };
  assert.equal((await call("/v1/push", { ...base, payload: "A".repeat(3004) })).status, 400);
  assert.equal((await call("/v1/push", { ...base, payload: "not base64!" })).status, 400);
  assert.equal((await call("/v1/push", { ...base, payload, collapse_id: "Z".repeat(65) })).status, 400);
});

test("an unregistered device answers 410", async () => {
  const t = await ticket();
  apnsAnswer = { status: 400, body: JSON.stringify({ reason: "BadDeviceToken" }) };
  assert.equal((await call("/v1/push", { platform: "ios", environment: "development", token: TOKEN, ticket: t, payload })).status, 410);
  apnsAnswer = { status: 410, body: JSON.stringify({ reason: "Unregistered" }) };
  assert.equal((await call("/v1/push", { platform: "ios", environment: "development", token: TOKEN, ticket: t, payload })).status, 410);
});

test("rejected credentials answer 502", async () => {
  const t = await ticket();
  apnsAnswer = { status: 403, body: JSON.stringify({ reason: "InvalidProviderToken" }) };
  const r = await call("/v1/push", { platform: "ios", environment: "development", token: TOKEN, ticket: t, payload });
  assert.equal(r.status, 502);
  assert.match((await r.json()).error, /InvalidProviderToken/);
});

test("an unconfigured relay says so", async () => {
  delete env.TICKET_SECRET;
  assert.equal((await call("/v1/register", { platform: "ios", environment: "production", token: TOKEN })).status, 503);
});

test("PAUSED stops pushes and sign-ups, not health", async () => {
  const t = await ticket();
  env.PAUSED = "1";
  assert.equal((await call("/v1/push", { platform: "ios", environment: "development", token: TOKEN, ticket: t, payload })).status, 503);
  assert.equal((await call("/v1/register", { platform: "ios", environment: "development", token: TOKEN })).status, 503);
  const h = await call("/health", undefined, "GET");
  assert.deepEqual(await h.json(), { ok: true, paused: true });
  assert.equal(sent.length, 0);
  env.PAUSED = "0";
  assert.equal((await call("/v1/push", { platform: "ios", environment: "development", token: TOKEN, ticket: t, payload })).status, 200);
});
