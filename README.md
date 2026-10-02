# MeshCore Home

A self-hosted web inbox for a [MeshCore](https://meshcore.io) companion radio. The server keeps one
connection to your home radio open, archives every message it receives in PostgreSQL (even when no
browser is open), and gives you a responsive chat interface for channels and direct messages from any
browser on your network.

> **Status: v0.1 (early).** Works end-to-end with the built-in **simulated radio**. The MeshCore
> TCP adapter is written against the `meshcore` Python client (2.3.14) but **has not yet been tested
> against real hardware**.

## What's in v0.1

- **First-run setup wizard**: creates the owner account and chooses the radio mode. Nothing
  installation-specific (passwords, radio address, hostnames) lives in this repository.
- **Radio modes**: *Simulated* (sample traffic for use without hardware), *MeshCore TCP* (Ethernet
  companion, e.g. RAK4631 + RAK13800), or *None*. You can switch modes from Settings at any time.
- Channels and DMs with unread counts, favorites, search, paginated history, date separators, a
  "new messages" divider, per-conversation drafts, and a UTF-8 byte budget in the composer.
- Honest delivery states: *Queued → Sending → Sent by radio / Acknowledged / No acknowledgement /
  Outcome uncertain / Failed / Expired*. Sends are idempotent, and an interrupted send is never
  re-sent automatically.
- Durable receive pipeline: the server fetches one message from the radio, commits it to the
  database, and only then fetches the next. Collection gaps (outages, pauses, restarts) are recorded
  and shown in Settings.
- Read state is shared across browsers and only moves forward. Realtime updates use an authenticated
  WebSocket, and the app falls back to REST resyncs if that connection drops.
- Maintenance pause/resume (releases the TCP connection for a maintenance client), device info,
  contacts with full public keys and local aliases, and JSON export.
- Light and dark themes. Layouts for phone, tablet, and desktop.

## Quick start (Docker Compose)

```bash
cp .env.example .env                    # then set POSTGRES_PASSWORD to a long random value
docker compose up -d --build
docker compose logs app | grep -A3 "setup token"
```

Open <http://localhost:8080> and follow the wizard. The **setup token** from the server log proves
you control the server, so nobody else on your network can claim the app before you do. The token
can only be used once; after setup, the app requires a sign-in.

## When your radio arrives

1. Flash the MeshCore **Ethernet companion** firmware (`RAK_4631_companion_radio_ethernet`, v1.17.0+).
2. Give the radio a DHCP reservation on your router.
3. In **Settings → Radio connection**, choose **MeshCore TCP**, enter the IP and port (default `5000`),
   use **Test reachability**, then **Save and reconnect**.
4. Watch the status card. If the handshake fails, the server keeps retrying with backoff and records
   the error. Use **Pause for maintenance** when you need a desktop/CLI client to talk to the radio.
5. Once real data is flowing, switch away from Simulated and use **Delete simulated data** to clear
   the sample conversations.

Live-hardware checks still pending: handshake, contact and channel sync, receive, channel send, DM
ACKs, and the exact message byte limits (`DM_MAX_BYTES` / `CHANNEL_MAX_BYTES` in
`backend/app/radio/base.py` are conservative defaults).

## Configuration

Environment variables cover deployment plumbing only. Everything else is set in the wizard and
stored in the database.

| Variable | Purpose | Default |
| --- | --- | --- |
| `DATABASE_URL` | `postgresql+asyncpg://user:pass@host:5432/db` (keep in a secret) | required |
| `RADIO_ENABLED` | `false` keeps the radio closed regardless of saved settings (restore/demo) | `true` |
| `SETUP_TOKEN` | Fixed first-run token instead of a random one | random |
| `COOKIE_SECURE` | `auto` / `true` / `false` | `auto` |
| `SESSION_DAYS` | Sign-in lifetime | `30` |
| `SEND_EXPIRY_SECONDS` | Queued sends older than this are not transmitted | `60` |

Run the app as a **single process** (`--workers 1`), because exactly one process may own the radio. A
PostgreSQL advisory lock enforces this: a second instance can serve history but will not connect to
the radio.

## Development

Requirements: Python 3.12+, Node 24+, Docker (for PostgreSQL).

```bash
docker run -d --name meshcore-dev-db -e POSTGRES_USER=meshcore -e POSTGRES_DB=meshcore \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" -p 127.0.0.1:55432:5432 postgres:18-alpine

cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
export DATABASE_URL="postgresql+asyncpg://meshcore:$POSTGRES_PASSWORD@127.0.0.1:55432/meshcore"
.venv/bin/alembic upgrade head
.venv/bin/uvicorn app.main:app --port 8080          # API on :8080

cd ../frontend && npm install && npm run dev         # UI on :5173 (proxies /api and /ws)
```

Tests run against a real, disposable PostgreSQL database:

```bash
export TEST_DATABASE_URL="postgresql+asyncpg://meshcore:$POSTGRES_PASSWORD@127.0.0.1:55432/meshcore_test"
cd backend && .venv/bin/pytest -q
```

API docs are served at `/api/docs`.

## Layout

```
backend/app/radio/      adapter contract, simulated radio, MeshCore TCP adapter, supervisor
backend/app/services/   persistence rules (positions, dedup, channel generations, sends)
backend/app/api/        REST routes (setup/auth, inbox, radio/status)
backend/migrations/     Alembic migrations
frontend/src/           React + TypeScript + Tailwind UI
```

## Not yet in v0.1

Kubernetes/Fleet manifests and the image publish + SHA-pin workflow, backup CronJob, contact-card
import, Playwright tests in CI, and live-hardware verification.
