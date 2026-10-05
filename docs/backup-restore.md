# Backup and restore

**Settings → Backup & restore** makes one encrypted file that holds the whole installation, and
restores it on the same or another installation, native or container.

## What a backup contains

- The owner account and API keys (password hashes and key fingerprints only).
- All settings: radio connection, map, notifications, bot, weather station, and so on.
- The message archive, contacts, channels and the repeater-admin history.
- **Native installs also:** the network and HTTPS settings, the HTTPS certificate and key, the DNS
  provider credentials, and the radio HAT's identity, contacts and channels (ZephCore). These files
  are root-only, so the installer's root helper packs them; the unencrypted copy exists only until it
  is encrypted into the backup.

Not included: sign-in sessions (everyone signs in again after a restore), and a TCP radio's own
contacts and settings, which live on the radio.

## Encryption

Every backup is encrypted with a passphrase you choose (at least 10 characters): AES-256-GCM with
the key derived using scrypt, sealed in authenticated chunks so a damaged, cut-off or altered file is
detected. The file can't be opened without the passphrase, and MeshCore Home doesn't store it. Keep
the passphrase somewhere safe: a lost passphrase means a lost backup.

## Where backups are kept

- **Native installs** keep backups in `/var/lib/meshcore-home/user-backups` until you delete them, with
  Download and Delete buttons in Settings. Download copies and keep them off the Pi:
  `uninstall --purge` deletes that folder.
- **Container installs** hand you the file to download straight away (the container has no persistent
  disk of its own).

## Restoring

Restore from **Settings → Backup & restore → Restore a backup…**, or on a fresh installation from the
setup wizard with **Restore a backup instead** (using the setup token). Upload the file and enter the
passphrase. MeshCore Home decrypts and checks the backup **before anything changes**, and lists what
will be restored, what won't be restored here and why, and anything to do afterwards. Then you
confirm.

| From → to | What happens |
| --- | --- |
| Native → native | Everything comes back. The certificate and DNS credentials are put back and the network settings applied; no new certificate is requested, so point the hostname at the new Pi if it moved. The HAT identity is restored; if no HAT is set up yet, setting it up uses it. |
| Native → container | App data only. HTTPS, the certificate, DNS credentials and the HAT identity aren't used (the cluster's Ingress handles HTTPS, and HATs need a Pi). A radio connection set to the HAT is cleared. |
| Container → native | App data only. The Pi keeps its own network and HTTPS settings. |
| From a newer version | Refused until you update this installation. Backups from older versions restore (new settings take their defaults). |

A restore replaces all data and signs everyone out; sign in with the backup's account. From
Settings, a copy of the data being replaced is saved first, encrypted with the same passphrase. On
native installs, the replaced certificate folder and HAT data are also kept as `*.before-restore`.

## Database dumps

These are separate from the encrypted backups above and are meant for repairs:

- **Native:** `sudo meshcore-home backup` writes an unencrypted database dump to
  `/var/lib/meshcore-home/backups`. Updates make one automatically before upgrading.
- **Kubernetes:** the `meshcore-db-backup` CronJob runs daily at 03:17 UTC. It writes
  `meshcore-<timestamp>.dump` and a `.sha256` file to the `meshcore-backups` volume, keeps 30 days,
  and always keeps the newest three. To run one now:
  `kubectl -n meshcore create job --from=cronjob/meshcore-db-backup backup-now`.

Restoring a dump in Kubernetes (fetch the dump from the backup volume, pause the radio in Settings
first):

```bash
kubectl -n meshcore exec -i deploy/meshcore-db -- \
  pg_restore --clean --if-exists -U meshcore -d meshcore < meshcore-<timestamp>.dump
kubectl -n meshcore rollout restart deploy/meshcore
```
