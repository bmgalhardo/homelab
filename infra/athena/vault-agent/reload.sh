#!/bin/sh
# Runs on the athena node host (not in a container). Watches the sentinel that
# Vault Agent touches after re-rendering a secret or cert, and reloads the
# consumers.
#
# Install:
#   cp /root/athena/vault-agent/reload.sh /root/athena/reload.sh
#   ( crontab -l 2>/dev/null; echo '*/5 * * * * /root/athena/reload.sh' ) | crontab -

set -eu
DIR=/root/athena
SENTINEL="$DIR/certs/.reload"
STAMP="$DIR/certs/.reload.done"

[ -f "$SENTINEL" ] || exit 0
[ -f "$STAMP" ] && [ ! "$SENTINEL" -nt "$STAMP" ] && exit 0

cd "$DIR"
# `up -d`, not `restart`: restart keeps the old env, so a re-rendered secrets/*.env never lands
docker compose up -d grafana
# Prometheus reloads in place, no restart
curl -sf -X POST http://localhost:9090/-/reload || true

touch "$STAMP"
logger -t athena-reload "reloaded grafana + prometheus after vault-agent render"
