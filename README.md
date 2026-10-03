# MeshCore Home

A self-hosted web inbox for a [MeshCore](https://meshcore.io) radio gateway. The server holds one
connection to a MeshCore companion radio on your network and archives every message it receives in
PostgreSQL, even when no browser is open. It gives you a responsive chat interface for channels and
direct messages from any browser that can reach it.

> **Status: early (v0.1.x).** Everything works end-to-end with the built-in **simulated radio**. The
> MeshCore TCP adapter is built on the official `meshcore` Python client (2.3.14) but has **not yet
> been verified against physical hardware**. Please report results.

## Contents

- [Features](#features)
- [Compatible radio gateways](#compatible-radio-gateways)
- [Install on a Raspberry Pi or Debian](#install-on-a-raspberry-pi-or-debian)
- [Quick start with Docker Compose](#quick-start-with-docker-compose)
- [Deploying on K3s with Rancher Continuous Delivery](#deploying-on-k3s-with-rancher-continuous-delivery)
- [Connecting a MeshCore TCP gateway](#connecting-a-meshcore-tcp-gateway)
- [Operations](#operations)
- [Configuration](#configuration)
- [Using your own fork](#using-your-own-fork)
- [Development](#development)

## Features

- **First-run setup wizard**: creates the owner account and chooses the radio connection. Nothing
  specific to an installation (passwords, addresses, hostnames) is stored in the repository or
  the image.
- **Radio modes**: *MeshCore TCP* (a network-attached companion radio), *Simulated* (sample traffic,
  no hardware required), or *None*. You can switch modes at any time in Settings.
- Channels and DMs with unread counts, favorites, search, paginated history, date separators, a
  "new messages" divider, per-conversation drafts, and a UTF-8 byte budget in the composer.
  The composer has an emoji picker. Browsers can't open the OS's own picker from a button, so this
  one is built in, draws emoji with the system emoji font, and shows the OS shortcut.
- **Add channel** (the **+** next to the search box) offers the same choices as the MeshCore app:
  create a private channel, join a private channel, join Public, join a hashtag channel, or scan a QR
  code. Hashtag and new private channels come with their key, a QR code, and a
  `meshcore://channel/add` link to share. A channel can have a **region scope**: messages you send on
  it only flood through repeaters serving that region. The scope is stored by this app and applied
  to each send, as the MeshCore app does. Scanning with the live camera needs HTTPS; over plain
  HTTP you can scan a photo instead.
- Honest delivery states: *Queued → Sending → Sent by radio / Acknowledged / No acknowledgement /
  Outcome uncertain / Failed / Expired*. Sends are idempotent, and an interrupted send is never
  re-sent automatically.
- Durable receive pipeline: the server fetches one message from the radio, commits it to the
  database, and only then fetches the next. Collection gaps (outages, pauses, restarts) are recorded
  and shown in Settings.
- Read state is shared across browsers and only moves forward. Realtime updates use an authenticated
  WebSocket, and the app falls back to REST resyncs if that connection drops.
- **Node map**: shows the companions, repeaters, room servers, and sensors heard by the gateway,
  at the positions they advertise (sharing a position is optional in MeshCore). You can filter by
  type and by when each node was last heard. Built with [Leaflet](https://leafletjs.com) and
  [OpenStreetMap](https://www.openstreetmap.org) tiles by default.
- **API keys** (Settings → API keys) let other services and scripts read messages, send them,
  and follow events live, using `Authorization: Bearer <key>`. A key can be *read only* or
  *read & write* and can expire. Keys are shown once and stored only as a fingerprint. Account,
  network, update, and radio settings stay limited to the web interface. See
  [docs/API.md](docs/API.md) for the full API guide; the running app also serves an interactive
  reference at `/api/docs`.
- **Node settings** (Settings → Configure node settings): change the connected radio's own
  configuration from the browser:
  - **Identity:** name, location, and whether adverts share the location.
  - **LoRa radio:** frequency, bandwidth, spreading factor, coding rate, TX power, and client repeat.
  - **Channels:** add, rename, remove, or set a region scope. Keys can be hashtag-derived, the
    Public key, a generated random key (shown once), or entered by hand. Private keys are never
    displayed afterwards.
  - **Contacts and routing:** auto-add contacts, extra ACKs, path hash size, and default flood scope.
  - **Other:** telemetry permissions, firmware variables, advanced timing, adverts, clock sync, and
    reboot.

  Values are checked against the firmware's own limits before anything is sent. Factory reset and
  private-key export/import are deliberately left out. Use official MeshCore tools for those.
- **Account page** (click your name, bottom left): change your username and password, and sign out.
- Right-click (or long-press) menu on conversations: info, mark as read, favorite, mute or unmute,
  and delete or clear history.
- **Notification sounds:** a chime for new incoming messages while the app is open in a browser tab.
  The global setting is *All messages*, *Direct messages only*, or *Off*, and you can override it per
  conversation from the right-click menu.
- **Contacts:** a compact, searchable list (name, device type, last heard) with type and status
  filters, sorting, and pagination (10/25/50 per page). Right-click or long-press a contact for:
  - **Details**
  - **Share:** copy a `meshcore://` contact link, or re-broadcast the advert to nearby nodes.
  - **Set path / Reset path:** choose the repeater route, or go back to flooding.
  - **Favorite:** sets the radio's favourite flag, so the radio won't overwrite the contact when its
    contact list is full.
  - **Block:** an app-side block. MeshCore radios can't block traffic, so the blocked contact's DMs,
    and channel messages under their name, are archived but hidden, never unread, and silent.
    Unblocking restores them.
  - **Remove contact:** removes it from the radio. The archive keeps the conversation.
- Maintenance pause/resume, device information, contacts with full public keys and local aliases,
  and JSON export.
- Light and dark themes. Layouts for phone, tablet, and desktop.

## Compatible radio gateways

The app talks to a radio running **MeshCore companion firmware with TCP (Ethernet/Wi-Fi)
transport**. This is the same companion protocol the MeshCore phone and desktop apps use, carried
over a TCP socket (port `5000` by default).

| Works | Does not work |
| --- | --- |
| MeshCore **companion** firmware with a TCP/Ethernet build, e.g. RAK4631 + RAK13800 Ethernet (+ RAK19018 PoE) with the `RAK_4631_companion_radio_ethernet` target, MeshCore v1.17.0 or later | MeshCore **repeater** or **room server** firmware |
| Any other board whose MeshCore companion build exposes the companion protocol over TCP | Meshtastic firmware, or MQTT-only gateways |
| | Companion radios reachable only by BLE or USB serial (not supported yet) |

**The gateway has its own identity.** It has its own MeshCore keys, contacts, and channels. Direct
messages reach this inbox only if they are addressed to the gateway's identity. Channel messages
appear if the gateway has the same channel configured (same name and key) and can hear the traffic.

## Install on a Raspberry Pi or Debian

A native install runs directly on the OS (no Docker), with its own local PostgreSQL. It works on a
**Raspberry Pi 4 or 5** with **Raspberry Pi OS (64-bit)**, or any 64-bit **Debian 12 (bookworm)** or
**Debian 13 (trixie)** system. 32-bit Raspberry Pi OS is not supported.

```bash
curl -fsSLo install.sh https://github.com/roach0816/MeshCoreHome/releases/latest/download/install.sh
sudo bash install.sh
```

The installer runs as a full-screen dashboard that stays in place instead of scrolling. It shows
the checklist of steps, what is happening now, and one overall progress bar. Each question
appears on the same screen with an explanation of what will change. When it finishes, a short
summary stays in your terminal; the full detail is in `/var/log/meshcore-home-install.log`.
Upgrades (`meshcore-home update`) and the uninstaller use the same screen. Small terminals (under
64×20), pipes, and `--plain` get plain line-by-line output instead.

The steps are:

1. **Check this system:** OS, 64-bit CPU, systemd, memory, disk space, and internet access.
2. **Choose the version:** the latest release.
3. **System packages:** lists exactly which apt packages it will install, with versions,
   descriptions, and download size, then asks **Install these packages? [Y/n]**.
4. **Review system changes:** asks for the port (default 8080), lists every change it will make
   (system user, directories, database, services, port), then asks **Make these changes? [Y/n]**.
5. **Download and verify** the release package (SHA-256 checksum).
6. **Install the app** into its own Python environment (prebuilt packages, no compiling).
7. **Set up the database:** a local PostgreSQL database, reached as the app's OS user, so there's
   no password.
8. **Start the service** and show the address to open and the **first-run setup token**.
9. **HTTPS (optional):** see [HTTPS on the Pi](#https-on-the-pi).
10. **Automatic security updates (optional, recommended):** turns on Debian's `unattended-upgrades`
    so OS security fixes install daily. It never upgrades MeshCore Home itself.

Answering **n** at any prompt cancels the installation. Re-running the installer is safe: it picks
up where a failed attempt stopped, and repairs a broken install.

| Where | What |
| --- | --- |
| `/opt/meshcore-home/releases/<version>` | The app. `current` points at the active version; the previous one is kept for rollback |
| `/etc/meshcore-home/meshcore-home.env` | Configuration (port, database URL), readable only by root and the app |
| `/var/lib/meshcore-home` | Update status, setup token, and database backups |
| `meshcore-home.service` | Runs as the unprivileged `meshcore` user, with the rest of the system read-only to it |

Manage it with the `meshcore-home` command:

```text
meshcore-home status         version, service state, web address
sudo meshcore-home https     set up HTTPS (or `https --disable` to go back to plain HTTP)
sudo meshcore-home security-updates   turn on automatic OS security updates
meshcore-home logs [-f]      application log
sudo meshcore-home update    upgrade to the latest release (same wizard, with a database backup)
sudo meshcore-home backup    back up the database now
sudo meshcore-home uninstall [--purge]   remove the app (--purge also deletes the data)
```

### HTTPS on the Pi

Without this step, the Pi serves **plain HTTP** on port 8080. Passwords and session cookies then
cross your network unencrypted, and some browser features are unavailable (the copy buttons, "Use
this device's location").

HTTPS is offered as the last step of the installer. You can also turn it on, change it, or turn it
off later in **Settings → Network & HTTPS** in the web interface, or with `sudo meshcore-home https`.
The Settings card shows the address, HTTPS status, certificate expiry, and app port. **Configure…**
opens a dialog for:

- the app port;
- HTTPS on/off, the hostname, the HTTPS port, and the HTTP→HTTPS redirect;
- the Let's Encrypt email, Cloudflare DNS validation, the API token, the DNS wait, and a staging
  option for testing;
- **Renew now**.

Before anything changes, the dialog lists exactly what will happen. The change is applied by a
root-only helper (`meshcore-home-config`); the web app itself never runs as root. If the app doesn't
come back afterwards, the previous configuration, including a previously saved token, is restored
automatically.

HTTPS uses:

- **nginx** in front of the app on ports 80/443. Port 80 redirects to HTTPS, and the app then
  listens on `127.0.0.1` only.
- A trusted **Let's Encrypt** certificate validated through **Cloudflare DNS** (DNS-01). The Pi
  doesn't need to be reachable from the internet, so it works for a private, LAN-only hostname.
- Debian's own `nginx`, `certbot`, and `python3-certbot-dns-cloudflare` packages. They're listed and
  confirmed **[Y/n]** before installing. `certbot.timer` renews the certificate automatically.

You need:

1. A hostname in a domain whose DNS is on Cloudflare (e.g. `meshcore.<your-domain>`).
2. A Cloudflare API token created with the **"Edit zone DNS"** template, limited to that zone. The
   installer asks for it with hidden input and stores it only in
   `/etc/letsencrypt/meshcore-home-cloudflare.ini`, readable by root only. It's never shown, logged,
   or given to the app.
3. A local DNS record (router, Pi-hole, etc.) pointing the hostname at the Pi's LAN address.

If the certificate can't be obtained, nothing changes: the app stays as it was, and you can retry.

### Updates

The app checks this repository's GitHub Releases for new versions every few hours. When one is
available, the version under your name in the sidebar changes to **Update to vX.Y.Z**, and
**Settings → Software updates** shows the release notes with an **Install** button. Installing:

1. downloads the release and verifies its checksum;
2. backs up the database;
3. installs the new version next to the current one and restarts the app (about a minute offline);
4. **rolls back automatically** if the new version doesn't start.

The web app itself never gets root access. It only asks for an update by writing the requested
version number to a file. A root-owned systemd unit (`meshcore-home-update`) then double-checks it
against the official releases before installing anything. A container install (Docker or
Kubernetes) also shows when an update is available, but is updated by redeploying.

## Quick start with Docker Compose

```bash
cp .env.example .env                    # then set POSTGRES_PASSWORD to a long random value
docker compose up -d --build
docker compose logs app | grep -A3 "setup token"
```

Open <http://localhost:8080> and follow the wizard. The **setup token** from the server log proves
you control the server, so nobody else on the network can claim the app before you do. It can only be
used once; after setup, the app requires a sign-in.

## Deploying on K3s with Rancher Continuous Delivery

Rancher Continuous Delivery (Fleet) watches the `deploy/k8s` directory of a Git repository and keeps
the cluster in sync with it. That directory is a Kustomize bundle containing:

- the app Deployment and Service
- a single-instance PostgreSQL Deployment and Service
- a daily backup CronJob

Each build of `main` publishes a multi-arch image (`linux/amd64` + `linux/arm64`) and commits that
image's commit SHA into `deploy/k8s/deployment.yaml`, so Fleet rolls out every release automatically
(see [Using your own fork](#using-your-own-fork)).

Anything specific to your environment is created **once by hand** from the `*.example.yaml`
templates, and is deliberately not part of the bundle:

| Resource | Template | Why it is outside the bundle |
| --- | --- | --- |
| Namespace | `namespace.example.yaml` | Removing the bundle must never delete the namespace and its data |
| Database Secret | `secrets.example.yaml` | Secrets never go in Git |
| Volumes (PVCs) | `pvc.example.yaml` | They need your StorageClass, and data must outlive the bundle |
| Ingress | `ingress.example.yaml` | Hostname, ingress class, and certificate issuer are site-specific |

`fleet.yaml` also sets `keepResources: true`, so deleting the Git repo from Rancher leaves running
workloads in place.

### Prerequisites

You need:

- A Rancher-managed K3s cluster. Arm64 (e.g. Raspberry Pi 5) and amd64 nodes both work.
- A StorageClass for the database and backups. If you use NFS, see the requirements in step 3.
- An ingress controller, plus cert-manager with a ClusterIssuer, for HTTPS.
- A DNS name for the app that resolves on your private network.
- Network reachability from the cluster nodes to the radio gateway's TCP port.

Run the `kubectl` commands below from the Rancher **kubectl shell** (the `>_` icon at the top right
of the cluster view) or any shell with access to the cluster.

### 1. Look up your cluster's values

```bash
kubectl get storageclass     # which class to use for the database and backups
kubectl get ingressclass     # e.g. traefik or nginx — check, don't assume
kubectl get clusterissuer    # the cert-manager issuer for the certificate
```

### 2. Create the namespace and database Secret

Create the namespace in Rancher (**Cluster → Projects/Namespaces → Create Namespace**, name
`meshcore`), or apply `deploy/k8s/namespace.example.yaml`. Then:

```bash
PW=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
kubectl -n meshcore create secret generic meshcore-db --from-literal=POSTGRES_PASSWORD="$PW"
echo "$PW"   # keep this in a password manager; restoring a backup elsewhere needs it
```

The password must be URL-safe, because the app embeds it in its database URL. `token_urlsafe` output
is URL-safe.

### 3. Create the volumes

Copy `deploy/k8s/pvc.example.yaml`, replace `<YOUR_NFS_STORAGECLASS>` with your StorageClass, and
apply it. Use Rancher's **Import YAML** button (top right), or **Storage → PersistentVolumeClaims →
Create → Edit as YAML**. This creates `meshcore-db-data` and `meshcore-backups`, 10 GiB each; adjust
the sizes as needed.

If the database volume is on NFS:

- **Ownership:** the database directory must be owned by **UID/GID 999** (the `postgres` user in
  the official image). After the claim binds, find its directory on the NFS server and run
  `chown -R 999:999 <dir>`. With root-squash enabled, the pod cannot fix ownership itself.
- **Mount and export:** the mount must be `hard` (check with `mount | grep nfs` on a node), and the
  export must honour synchronous writes. If your NFS server can't meet that, put `meshcore-db-data`
  on local or block storage and use NFS only for `meshcore-backups`.

### 4. Add the Git repo to Continuous Delivery

In Rancher: **☰ → Continuous Delivery → Git Repos**. In the workspace dropdown, choose
`fleet-default` to deploy to a downstream cluster, or `fleet-local` if Rancher runs on the same
cluster. Then **Add Repository**:

| Field | Value |
| --- | --- |
| Name | `meshcore-home` |
| Repository URL | `https://github.com/roach0816/MeshCoreHome.git` (or your fork) |
| Branch | `main` |
| Paths | `deploy/k8s` |
| Deploy To | your K3s cluster |

A public repository needs no Git credentials. Click **Create**, and wait for the Git repo and its
bundle to show **Active/Ready**. Fleet polls for changes about once a minute.

The same thing as YAML (for **Edit as YAML**):

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
kubectl -n meshcore get pods                       # meshcore and meshcore-db Running 1/1
kubectl -n meshcore get deploy meshcore -o jsonpath='{..image}{"\n"}'
```

### 5. Run the setup wizard

Get the one-time setup token: open **Workloads → Deployments → meshcore → ⋮ → View Logs** in
Rancher, or run:

```bash
kubectl -n meshcore logs deploy/meshcore | grep -A3 "setup token"
```

You can finish setup before the Ingress exists. Run
`kubectl -n meshcore port-forward svc/meshcore 8080:80`, then open <http://localhost:8080>. In the
wizard, choose **MeshCore TCP** if the gateway is already on the network. Otherwise choose
**Simulated** or **Decide later**, and connect it afterwards (see
[Connecting a MeshCore TCP gateway](#connecting-a-meshcore-tcp-gateway)).

### 6. Create the Ingress

The app doesn't need to be told its hostname. You choose it here, and it lives only in the
Ingress and in your DNS.

**a. Choose the hostname and find where its DNS record should point.** The A record for the
hostname points at your **ingress controller**, not at the app pod:

```bash
HOST=meshcore.example.com     # the fully qualified name you want to use
kubectl get svc -A | grep -iE 'traefik|ingress'
```

Use the controller Service's `EXTERNAL-IP`. On K3s, the bundled Traefik is exposed by ServiceLB
(klipper), which usually lists your node IPs; any of them works, and a virtual IP (e.g. kube-vip or
MetalLB) is best if you have one. If you already have another app behind the same ingress, its record
points to the same place:

```bash
kubectl get ingress -A        # the ADDRESS column shows the IP(s) existing hosts use
```

**b. Create the DNS record** `HOST → that IP` on your **private** DNS (local DNS server or router).
Don't port-forward the app to the internet. Check it from a machine on your network:

```bash
dig +short "$HOST"            # or: nslookup "$HOST"
```

**c. Create the Ingress.** Fill in the three placeholders in `deploy/k8s/ingress.example.yaml`:
the hostname (in both `host:` and `tls.hosts`), the ingress class (from step 1), and the ClusterIssuer (from step 1).
Then either:

- **In Rancher:** **Service Discovery → Ingresses → Create → Edit as YAML**, then paste the filled-in
  file. Use the YAML editor rather than the guided form, which can drop `pathType` or the TLS
  settings.
- **With kubectl**, from a checkout of this repo:
  ```bash
  sed -e "s/<YOUR_HOSTNAME>/$HOST/g" \
      -e "s/<YOUR_INGRESS_CLASS>/traefik/" \
      -e "s/<YOUR_CLUSTER_ISSUER>/<issuer-name>/" \
      deploy/k8s/ingress.example.yaml | kubectl apply -f -
  ```

**d. Verify the certificate issued.** If your hostname is in a public domain but resolves to a
private IP, the ClusterIssuer must use a **DNS-01** solver; HTTP-01 can't reach a private app.

```bash
kubectl -n meshcore get ingress meshcore -o yaml   # cert-manager annotation and tls: block present
kubectl -n meshcore get certificate -w             # wait for READY=True
```

### 7. Verify

Open `https://<YOUR_HOSTNAME>` and sign in. Then check:

- **Realtime updates:** the status line under the inbox name should not say "live updates paused".
  If it does, WebSockets are not getting through the ingress.
- **Server status:** **Settings** shows the radio state, the app version, and any collection gaps.

## Connecting a MeshCore TCP gateway

### 1. Prepare the gateway

- Flash MeshCore **companion** firmware with TCP/Ethernet support for your board. For a RAK4631
  with an Ethernet module, use `RAK_4631_companion_radio_ethernet` from MeshCore v1.17.0 or later.
- Attach the antenna before transmitting. Then, using a MeshCore client, set the gateway's name.
  Match the radio settings (frequency, bandwidth, spreading factor, coding rate) to your mesh, and add
  the channels you want archived, with their exact names and keys.
- Back up the gateway's identity and configuration using the firmware's or client's export
  facilities.

### 2. Give it a stable address and make it reachable

- Create a **DHCP reservation** (or static IP) for the gateway, and note its IP or hostname.
- The app pod connects **out** to the gateway over plain unicast TCP (default port `5000`). This
  works with normal pod networking: no `hostNetwork`, multicast, or mDNS. Use an IP address, or a
  DNS name the cluster can resolve. `.local` names will not resolve inside pods.
- **Firewall:** the gateway's TCP port gives full control of the radio. Allow it only from your
  cluster nodes (pod traffic usually leaves through the node's IP) and from any maintenance machine.
  Never expose it to the internet or to guest networks.

### 3. Connect it in the app

1. Go to **Settings → Radio connection** and choose **MeshCore TCP**.
2. Enter the gateway's IP or hostname and port, then click **Test reachability**. This only checks
   that the TCP port is open from the server.
3. Click **Save and reconnect**. The status card should move through *Connecting* to *Radio
   connected*. **Settings → Device** then shows the gateway's name, public key, firmware, radio
   settings, and channels.
4. Send a test message from another MeshCore device to one of the gateway's channels, or as a DM to
   the gateway. Check that it appears, then reply from the web app.

If you used the simulated radio first, use **Settings → Data → Delete simulated data** to remove the
sample conversations. This option is available once the mode is no longer *Simulated*.

### Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "Not reachable" / timed out | Wrong IP or port, a firewall blocks the cluster, or the gateway is offline |
| Reachable, but status shows "companion did not answer the handshake" | The device on that port is not running MeshCore companion firmware, or another client is holding the connection |
| Connected, but no channel messages | The channel name or key differs from the rest of the mesh, or the gateway can't hear the traffic (check placement and antenna) |
| DMs don't arrive | The sender is messaging a different node; DMs must be addressed to the gateway's own identity |
| "Read-only (another instance owns radio)" | A second copy of the app is running against the same database; only one may own the radio |

The server retries with exponential backoff (up to 30 s) and never needs a restart for an ordinary
radio outage. When you need a desktop or CLI client to talk to the gateway directly, use **Pause for
maintenance**, which releases the TCP connection. Resume when you're done.

**Message size:** the composer enforces conservative UTF-8 byte limits (`DM_MAX_BYTES` and
`CHANNEL_MAX_BYTES` in `backend/app/radio/base.py`). Confirm them against your firmware before
relying on them.

## Operations

- **Updating:** each successful build of `main` pins a new image, and Fleet rolls it out within a
  few minutes. Pods use `strategy: Recreate`, so expect a short interruption on each rollout. The
  gateway keeps messages it receives in that window queued (its buffer is finite).
- **Backups:** the `meshcore-db-backup` CronJob runs daily at 03:17 UTC. It writes
  `meshcore-<timestamp>.dump` and a `.sha256` file to the `meshcore-backups` volume, keeps 30 days,
  and always keeps the newest three. To run one now:
  `kubectl -n meshcore create job --from=cronjob/meshcore-db-backup backup-now`. Copy backups off the
  storage server as well.
- **Restore:** fetch the dump from the backup volume, pause the radio in Settings, then:
  ```bash
  kubectl -n meshcore exec -i deploy/meshcore-db -- \
    pg_restore --clean --if-exists -U meshcore -d meshcore < meshcore-<timestamp>.dump
  kubectl -n meshcore rollout restart deploy/meshcore
  ```
- **Demo or restore environments:** set `RADIO_ENABLED=false` on the app container so it never
  connects to a radio.
- **Uninstalling:** delete the Git repo in Continuous Delivery. Because of `keepResources: true`,
  workloads stay in place; delete them, then the namespace, when you're sure you no longer need the
  data.

## Configuration

Environment variables cover deployment plumbing only. Everything else is set in the wizard or in
Settings, and stored in the database.

| Variable | Purpose | Default |
| --- | --- | --- |
| `DATABASE_URL` | `postgresql+asyncpg://user:pass@host:5432/db` (keep in a secret) | required |
| `RADIO_ENABLED` | `false` keeps the radio closed regardless of saved settings | `true` |
| `SETUP_TOKEN` | Fixed first-run token instead of a random one | random |
| `COOKIE_SECURE` | `auto` / `true` / `false` | `auto` |
| `SESSION_DAYS` | Sign-in lifetime | `30` |
| `SEND_EXPIRY_SECONDS` | Queued sends older than this are not transmitted | `60` |
| `MESHCORE_INSTALL_KIND` | `native` enables in-place upgrades from the UI (set by the installer) | `container` |
| `MESHCORE_STATE_DIR` | Writable state directory for a native install | — |
| `UPDATE_REPO` | GitHub `owner/repo` checked for new releases; empty disables update checks | this repo |
| `RELEASE_NOTES_URL` | Where the version number links (`{version}` is substituted); empty for no link | this repo's GitHub releases |

**Map tiles and privacy:** the browser loads map tiles directly from the configured tile server.
That server sees your IP address, which map areas you view, and the app's origin (the tile
requests send the origin as `Referer`, as OpenStreetMap's tile policy expects). Nothing else is sent:
no message content, node names, or keys. OpenStreetMap's public tiles suit light personal use. To
avoid any third-party requests, point **Settings → Map** at a self-hosted XYZ tile server.

Run the app as a **single process** (`--workers 1`, one replica), because exactly one process may own
the radio. A PostgreSQL advisory lock enforces this: a second instance can serve history but will not
connect to the radio.

## Using your own fork

The CI workflow (`.github/workflows/ci.yml`) handles forks automatically. On each push to `main` it:

1. Runs the backend tests against PostgreSQL, lints and builds the frontend, and shellchecks the
   installer.
2. Builds and publishes `ghcr.io/<owner>/<repo>:<commit-sha>` (plus `:latest`) for `linux/amd64`
   and `linux/arm64`.
3. Commits that image reference into `deploy/k8s/deployment.yaml` as `github-actions[bot]`, with
   `[skip ci]`. This step is skipped if `main` has moved on since the build started.

To deploy from a fork:

- **Wait for the pin:** push to your fork's `main` and wait for the first `deploy: pin image …`
  commit before adding the fork in Continuous Delivery.
- **Native releases:** pushing a `vX.Y.Z` tag runs `release-assets.yml`, which attaches
  `meshcore-home-X.Y.Z.tar.gz`, `install.sh` and `SHA256SUMS` to the GitHub release. Native installs
  update from those files. Point the installer at your fork with
  `MESHCORE_HOME_REPO=<owner>/<repo> sudo -E bash install.sh`.
- **Make the image pullable:** make the GHCR package public (**GitHub → Packages → your package →
  Package settings → Change visibility**), or give the cluster a pull secret:
  ```bash
  kubectl -n meshcore create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username=<GITHUB_USER> --docker-password=<READ_PACKAGES_TOKEN>
  kubectl -n meshcore patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
  ```
- **Release notes link:** set `RELEASE_NOTES_URL` on the app container (for example
  `https://github.com/<owner>/<repo>/releases/tag/v{version}`) so the version number in the app
  links to your fork's releases.
- **Leave `[skip ci]` to the bot:** it is reserved for the deploy-pin commit. Don't use it in your
  own commit messages.

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

```
backend/app/radio/      adapter contract, simulated radio, MeshCore TCP adapter, supervisor
backend/app/services/   persistence rules (positions, dedup, channel generations, sends)
backend/app/api/        REST routes (setup/auth, inbox, radio/status)
backend/migrations/     Alembic migrations
frontend/src/           React + TypeScript + Tailwind UI
deploy/k8s/             Fleet bundle (kustomization) + *.example.yaml templates applied by hand
```

### Not yet included

Physical-hardware verification of remote node configuration, contact-card import, BLE/serial gateways, Playwright tests in CI, NetworkPolicies, and
physical-hardware verification of the MeshCore TCP adapter.
