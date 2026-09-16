#!/bin/sh
# Export every Grafana dashboard to grafana/dashboards/ as provisioning JSON.
#
# Grafana's dashboard provisioning is one-way: it imports files into grafana.db
# and never writes back. This stack runs Grafana stateless (no grafana.db
# volume), so a dashboard built in the UI lives only in the container and is
# lost on the next recreate. Run this to make it durable, then commit the file.
#
#   /root/athena/grafana/export-dashboards.sh
#
# Credentials come from the vault-agent-rendered secrets/grafana.env.
# Writes only when content actually changed, so it is safe to cron.

set -eu
DIR=/root/athena
OUT="$DIR/grafana/dashboards"
API=https://localhost:3000

. "$DIR/secrets/grafana.env"
AUTH="${GF_SECURITY_ADMIN_USER}:${GF_SECURITY_ADMIN_PASSWORD}"

# -k: Grafana serves the internal leaf on localhost, whose CN is the node name.
g() { docker exec grafana curl -sk -u "$AUTH" "$API$1"; }

mkdir -p "$OUT"
count=0 changed=0

for uid in $(g /api/search?type=dash-db | jq -r '.[].uid'); do
  doc=$(g "/api/dashboards/uid/$uid")
  folder=$(printf '%s' "$doc" | jq -r '.meta.folderTitle // ""')
  title=$(printf '%s' "$doc" | jq -r '.dashboard.title')

  # Strip instance-local fields: `id` must be null for import, and `version`
  # changes on every save, which would churn git for no reason.
  body=$(printf '%s' "$doc" | jq -S '.dashboard | .id = null | del(.version)')

  slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
  if [ -n "$folder" ]; then
    fslug=$(printf '%s' "$folder" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
    mkdir -p "$OUT/$fslug"; dest="$OUT/$fslug/$slug.json"
  else
    dest="$OUT/$slug.json"
  fi

  count=$((count+1))
  if [ -f "$dest" ] && [ "$(cat "$dest")" = "$body" ]; then
    echo "  unchanged: ${dest#$OUT/}"
  else
    printf '%s\n' "$body" > "$dest"
    changed=$((changed+1))
    echo "  written:   ${dest#$OUT/}"
  fi
done

echo "$count dashboard(s), $changed written"
[ "$changed" -gt 0 ] && echo "commit them: infra/athena/grafana/dashboards/"
exit 0
