# Agent notes for MeshCore Home

## Ground rules
- **Public repository.** Never commit secrets or installation specifics: no passwords, radio IPs,
  hostnames, channel keys, cluster names, StorageClass names, or issuers. Installation values come from
  the first-run wizard (stored in the DB) or from environment/Secrets. Examples use placeholders
  like `<YOUR_HOSTNAME>`.
- Run as one process with one radio owner (`--workers 1`; K8s `replicas: 1`, `strategy: Recreate`).
- Radio code goes through `app/radio/base.py:RadioAdapter`. Do not call the `meshcore` library
  from anywhere else.
- Test against real PostgreSQL (`TEST_DATABASE_URL`), never SQLite.
- Don't claim hardware behavior is verified unless it was tested on the real RAK companion. Label
  simulated results as simulated.

## Deployment conventions (owner's K3s/Rancher guide)
- Multi-arch images (`linux/amd64` + `linux/arm64`) on GHCR. Deployments are pinned to the commit
  SHA, never `:latest`. CI's deploy-pin commit is the only place `[skip ci]` may appear.
- Fleet tracks `deploy/k8s`. Keep Ingress and Secrets as `*.example.yaml` templates, excluded from
  the bundle. The real Ingress is created by hand ("Edit as YAML", with `pathType: Prefix`, the
  cert-manager annotation, and a `tls:` block).
- Use small resource requests sized for Pi 5 nodes, and probes against real health endpoints
  (`/health/live`, `/health/ready`).

## Release workflow
1. Bump the version: `backend/app/config.py:APP_VERSION`, `backend/pyproject.toml`, and
   `frontend/package.json`.
2. Regenerate lockfiles with their tools; never hand-edit them.
3. Build, lint, and test. For UI changes, drive a real browser and inspect screenshots at roughly
   390/768/1440 px.
4. Stage specific files and review for secrets. Commit, then tag `vX.Y.Z` (annotated).
5. Fetch, and merge (not rebase) any CI deploy-pin commit. Push the branch and tag, create the GitHub
   release, and watch CI to completion.
