# MeshHome push relay

A Cloudflare Worker that forwards push notifications from MeshHome servers to Apple, for the
MeshHome iOS app. MeshHome uses it only when the owner turns on push notifications
(Settings → Notifications). See [docs/push-notifications.md](../docs/push-notifications.md) for how
it fits together.

Why a relay: Apple delivers a push only when it is signed with the app's push key. That key can't
be given to every self-hosted server, so the relay holds it and forwards on their behalf.

What the relay sees and keeps:

- **Sees:** the phone's push token, an encrypted blob, the sending server's IP address and the time.
  MeshHome encrypts the sender and text with a key that only the phone and its MeshHome server
  have, so the relay can't read them, and neither can Apple.
- **Keeps:** nothing. It has no storage, and it logs no tokens or payloads.

Abuse protection: a phone gets a **ticket** for its push token from the relay (`POST /v1/register`)
and gives it to its own MeshHome server. The relay forwards only pushes that carry the matching
ticket, so nobody can push to a phone that didn't sign up with them. Pushes and registrations are
also rate-limited.

## API

`POST /v1/register` (called by the app)

```json
{ "platform": "ios", "environment": "production", "token": "<hex APNs token>" }
→ { "ticket": "<base64url>" }
```

`POST /v1/push` (called by MeshHome servers)

```json
{ "platform": "ios", "environment": "production", "token": "<hex>", "ticket": "<base64url>",
  "payload": "<base64 AES-256-GCM ciphertext>", "collapse_id": "<optional hex, up to 64>" }
→ 200 { "ok": true }   410: the phone is gone (forget it)   403: wrong ticket   429: rate limited
```

`environment` is `development` for builds run from Xcode and `production` for TestFlight and the
App Store. `GET /health` answers `{ "ok": true }`.

## Deploying

The relay only works with the push key of the team that publishes the app, so there is one relay
for the published app (`https://push.meshhome.app`). These are the steps its maintainer follows.

1. Create an APNs key: developer.apple.com → Certificates, IDs & Profiles → **Keys** → **+** →
   **Apple Push Notifications service (APNs)**. Download the `.p8` file and note its Key ID.
2. From this directory:

   ```bash
   npx wrangler login
   npx wrangler secret put APNS_KEY       < AuthKey_XXXXXXXXXX.p8
   npx wrangler secret put APNS_KEY_ID    # the 10-character Key ID
   npx wrangler secret put APNS_TEAM_ID   # your Apple developer Team ID
   openssl rand -base64 48 | npx wrangler secret put TICKET_SECRET
   npx wrangler deploy
   ```

   Set `BUNDLE_ID` in `wrangler.toml` if your app's bundle ID differs. To serve it on your own
   domain, uncomment `routes` (the domain's DNS must be on Cloudflare).
3. Keep the `.p8` file somewhere safe and out of this repository. Changing `TICKET_SECRET`
   invalidates every phone's ticket; phones sign up again the next time the app opens.

## Turning it off

To stop all push notifications at once (for example if the relay is being abused), set a
variable on the Worker: Cloudflare dashboard → **Workers & Pages** → `meshhome-push-relay` →
**Settings** → **Variables and Secrets** → **Add** → type *Text*, name `PAUSED`, value `1` →
**Deploy**. It takes effect within seconds: the relay answers every push and sign-up with
"push notifications are paused", which MeshHome servers show as the last error. Nothing else
in MeshHome is affected. To turn it back on, delete the variable (or set it to `0`).

From a terminal instead: `printf 1 | npx wrangler secret put PAUSED` to pause and
`echo y | npx wrangler secret delete PAUSED` to resume. `GET /health` shows `"paused": true` while it's off.

## Testing

```bash
node --test
```
