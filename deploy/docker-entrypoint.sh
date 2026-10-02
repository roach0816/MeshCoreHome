#!/bin/sh
set -eu
# Apply database migrations (serialised by an advisory lock) before starting the app.
# Set SKIP_MIGRATIONS=1 when an init container already ran them.
if [ "${SKIP_MIGRATIONS:-0}" != "1" ]; then
  attempt=0
  until alembic upgrade head; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then echo "migrations failed; giving up" >&2; exit 1; fi
    echo "database not ready yet; retrying in 2s ($attempt/30)" >&2
    sleep 2
  done
fi
exec "$@"
