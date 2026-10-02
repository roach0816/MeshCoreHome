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
deploy/k8s/             Fleet bundle (kustomization) + *.example.yaml templates applied by hand
```

## Deploying to K3s with Rancher Continuous Delivery

Every push to `main` deploys automatically:

```
git push → CI (tests) → multi-arch image to ghcr.io/roach0816/meshcorehome:<commit-sha>
        → CI bot commits the new SHA into deploy/k8s/deployment.yaml ([skip ci])
        → Fleet (Rancher Continuous Delivery) sees the manifest change → rolls out the app
```

Fleet deploys only `deploy/k8s` (via `kustomization.yaml`): the app, PostgreSQL, their Services,
and a daily backup CronJob. Anything specific to your environment is created once by hand from the
`*.example.yaml` templates and is **not** part of the bundle:

- the namespace
- the database Secret
- the PersistentVolumeClaims (which need your StorageClass)
- the Ingress

Because those stay outside the bundle, real values never land in this public repo, and removing
the bundle can never delete your data. `fleet.yaml` also sets `keepResources: true`.

You need a Rancher-managed K3s cluster with:

- a StorageClass for the database (NFS works if it meets the requirements in step 4)
- an ingress controller
- cert-manager with a ClusterIssuer
- internal DNS

Run the `kubectl` commands below from the Rancher **kubectl shell** (the `>_` icon at the top right
of the cluster view) or any shell with access to the cluster.

### 1. Let CI publish the first image

Pushing to `main` runs CI. When it goes green, CI publishes the image and a
`github-actions[bot]` commit replaces `pending-first-ci-build` in `deploy/k8s/deployment.yaml` with
a commit SHA. **Don't add the Git repo to Fleet until that pin commit exists**, or the first rollout
will fail to pull.

Then make the image pullable by the cluster. Either:

- **Public (simplest):** GitHub → your profile → **Packages** → `meshcorehome` → **Package settings** →
  **Change visibility → Public**. The code is already public.
- **Private:** create a GitHub token with `read:packages`, then (after step 3):
  ```bash
  kubectl -n meshcore create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username=<GITHUB_USER> --docker-password=<TOKEN>
  kubectl -n meshcore patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
  ```

### 2. Look up your cluster's values

```bash
kubectl get storageclass     # the NFS (or other) class for the database and backups
kubectl get ingressclass     # e.g. traefik or nginx — don't assume
kubectl get clusterissuer    # the cert-manager issuer to use
```

### 3. Create the namespace and database Secret

Create the namespace in Rancher (**Cluster → Projects/Namespaces → Create Namespace**, name
`meshcore`), or apply `deploy/k8s/namespace.example.yaml`. Then:

```bash
PW=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
kubectl -n meshcore create secret generic meshcore-db --from-literal=POSTGRES_PASSWORD="$PW"
echo "$PW"   # store this in your password manager; restores need it
```

The password must be URL-safe, because the app embeds it in its database URL. `token_urlsafe` output
is URL-safe.

### 4. Create the volumes

Copy `deploy/k8s/pvc.example.yaml`, replace `<YOUR_NFS_STORAGECLASS>`, and apply it with Rancher's
**Import YAML** button, or with **Storage → PersistentVolumeClaims → Create → Edit as YAML**. This
creates `meshcore-db-data` and `meshcore-backups`, 10 GiB each.

If the database lives on NFS:

- **Ownership:** the database directory must be owned by **UID/GID 999** (the image's `postgres`
  user). After the claim binds, find its directory on the NAS and run `chown -R 999:999 <dir>`. A
  root-squashed export won't let the pod fix ownership itself.
- **Mount and export:** the mount must be `hard` (check with `mount | grep nfs` on a node), and the
  export must honour synchronous writes. If the NAS can't meet that, put the database claim on
  local/block storage and keep NFS for `meshcore-backups` only.

### 5. Add the Git repo to Continuous Delivery

In Rancher: **☰ → Continuous Delivery → Git Repos**. In the workspace dropdown, choose
`fleet-default` for a downstream cluster, or `fleet-local` if Rancher runs on this same cluster.
Then **Add Repository**:

| Field | Value |
| --- | --- |
| Name | `meshcore-home` |
| Repository URL | `https://github.com/roach0816/MeshCoreHome.git` |
| Branch | `main` |
| Paths | `deploy/k8s` |
| Deploy To | your K3s cluster |

No Git credentials are needed, because the repo is public. Click **Create**, and wait for the Git
repo and its bundle to show **Active/Ready**. Fleet polls about once a minute. The equivalent YAML
(for **Edit as YAML**) is:

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: meshcore-home
  namespace: fleet-default          # or fleet-local
spec:
  repo: https://github.com/roach0816/MeshCoreHome.git
  branch: main
  paths: [deploy/k8s]
  targets:
    - clusterName: <YOUR_CLUSTER_NAME>
```

Check the rollout:

```bash
kubectl -n meshcore get pods                       # meshcore and meshcore-db should be Running 1/1
kubectl -n meshcore get deploy meshcore -o jsonpath='{..image}{"\n"}'
```

### 6. Run the setup wizard

Get the one-time setup token: open **Workloads → Deployments → meshcore → ⋮ → View Logs** in
Rancher, or run:

```bash
kubectl -n meshcore logs deploy/meshcore | grep -A3 "setup token"
```

You can finish setup before the Ingress exists. Run
`kubectl -n meshcore port-forward svc/meshcore 8080:80`, then open <http://localhost:8080>.

### 7. Create the private Ingress

In Rancher: **Service Discovery → Ingresses → Create → Edit as YAML**. Avoid the guided form: it
can drop `pathType` or the TLS settings. Paste `deploy/k8s/ingress.example.yaml` with your hostname,
ingress class, and issuer filled in.

Then point an **internal** DNS record (Pi-hole/AdGuard/router) at the ingress address. Don't add a
port-forward to the internet. Verify the certificate actually issued:

```bash
kubectl -n meshcore get ingress meshcore -o yaml   # annotation and tls: block are present
kubectl -n meshcore get certificate -w             # wait for READY=True
```

Open `https://<YOUR_HOSTNAME>` and sign in. The status line under your inbox name should not say
"live updates paused"; if it does, WebSockets aren't getting through the ingress.

### 8. Connect the radio

Once the RAK companion has its DHCP reservation, go to **Settings → Radio connection → MeshCore
TCP** and enter its IP and port `5000`. The pod reaches it with ordinary unicast TCP, so no
`hostNetwork` is needed. Restrict the radio's TCP port at your firewall to the cluster nodes'
addresses.

### Day-to-day

- **Updating:** push to `main`. CI tests, publishes, and pins, and Fleet rolls out within a few
  minutes. The pods use `strategy: Recreate`, so expect a brief outage on each rollout. Messages the
  radio receives in that window stay queued on the radio.
- **Backups:** `meshcore-db-backup` runs daily at 03:17 UTC. It writes
  `meshcore-<timestamp>.dump` and a `.sha256` file to the `meshcore-backups` volume, keeps 30 days,
  and always keeps the newest three. To run one now:
  `kubectl -n meshcore create job --from=cronjob/meshcore-db-backup backup-now`. Replicate the
  backup directory off the NAS.
- **Restore** (copy the dump from the backup share first). Pause the radio in Settings, then:
  ```bash
  kubectl -n meshcore exec -i deploy/meshcore-db -- \
    pg_restore --clean --if-exists -U meshcore -d meshcore < meshcore-<timestamp>.dump
  kubectl -n meshcore rollout restart deploy/meshcore
  ```
- **Maintenance client:** **Settings → Pause for maintenance** releases the radio's TCP connection.
  The pause is saved, so a Fleet re-sync won't undo it.
- **Demo or restore environments:** set `RADIO_ENABLED=false` on the app so it never connects to
  the radio.

## Not yet included

Contact-card import, Playwright tests in CI, NetworkPolicies, and live-hardware verification of the
MeshCore TCP adapter.
