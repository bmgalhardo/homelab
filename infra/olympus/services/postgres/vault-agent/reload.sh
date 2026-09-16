#!/bin/sh
# Runs on the postgres VM host. Watches the sentinel vault-agent touches after
# re-issuing the cert and makes postgres re-read it.
#
# postgres re-reads ssl_cert_file/ssl_key_file on SIGHUP, so no restart and no
# dropped connections — unlike grafana on athena, which has to be recreated.
#
# Install:
#   cp /root/vault-agent/reload.sh /root/reload.sh
#   ( crontab -l 2>/dev/null; echo '*/5 * * * * /root/reload.sh' ) | crontab -

set -eu
DIR=/root
SENTINEL="$DIR/certs/.reload"
STAMP="$DIR/certs/.reload.done"

[ -f "$SENTINEL" ] || exit 0
[ -f "$STAMP" ] && [ ! "$SENTINEL" -nt "$STAMP" ] && exit 0

cd "$DIR"
docker compose exec -T postgres pg_ctl reload -D /var/lib/postgresql/data

touch "$STAMP"
logger -t postgres-reload "postgres reloaded after vault-agent cert renewal"
