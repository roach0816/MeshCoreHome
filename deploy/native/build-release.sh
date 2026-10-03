#!/usr/bin/env bash
# Build the native release package: dist-release/meshcore-home-X.Y.Z.tar.gz (+ SHA256SUMS).
# Requires the frontend to be built first (frontend/dist). Used by CI on every v* tag.
set -euo pipefail
export COPYFILE_DISABLE=1  # macOS tar: don't add AppleDouble "._*" files
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(sed -n 's/^APP_VERSION = "\(.*\)"/\1/p' "$ROOT/backend/app/config.py")
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot read APP_VERSION" >&2; exit 1; }
[[ -f $ROOT/frontend/dist/index.html ]] || { echo "Build the frontend first (npm run build)" >&2; exit 1; }

OUT=${1:-$ROOT/dist-release}
NAME=meshcore-home-$VERSION
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
D=$STAGE/$NAME
mkdir -p "$D/deploy/native"
cp -R "$ROOT/backend/app" "$ROOT/backend/migrations" "$ROOT/backend/alembic.ini" "$ROOT/backend/requirements.txt" "$D/"
cp -R "$ROOT/frontend/dist" "$D/static"
cp -R "$ROOT/deploy/native/install.sh" "$ROOT/deploy/native/meshcore-home" "$ROOT/deploy/native/tls-hook" \
  "$ROOT/deploy/native/status.py" "$ROOT/deploy/native/radio-hat-run" "$ROOT/deploy/native/zephcore.lock" \
  "$ROOT/deploy/native/systemd" "$D/deploy/native/"
cp "$ROOT/README.md" "$ROOT/THIRD_PARTY_NOTICES.md" "$D/"
[[ -f $ROOT/LICENSE ]] && cp "$ROOT/LICENSE" "$D/"
echo "$VERSION" >"$D/VERSION"
find "$D" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$D" -type f \( -name '*.pyc' -o -name '._*' -o -name .DS_Store \) -delete
rm -rf "$D/app/static"
chmod 755 "$D/deploy/native/install.sh" "$D/deploy/native/meshcore-home" "$D/deploy/native/tls-hook" \
  "$D/deploy/native/radio-hat-run"

mkdir -p "$OUT"
# Reproducible-ish archive: fixed ownership and sorted entries.
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$STAGE" -czf "$OUT/$NAME.tar.gz" "$NAME" 2>/dev/null ||
  tar -C "$STAGE" -czf "$OUT/$NAME.tar.gz" "$NAME"
cp "$ROOT/deploy/native/install.sh" "$OUT/install.sh"
(cd "$OUT" && sha256sum "$NAME.tar.gz" install.sh >SHA256SUMS 2>/dev/null || shasum -a 256 "$NAME.tar.gz" install.sh >SHA256SUMS)
echo "$OUT/$NAME.tar.gz"
