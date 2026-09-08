#!/usr/bin/env bash
# Vault-side setup for the athena stack Vault Agent (AppRole auth).
# The stack runs on the "athena" node; deploy dir is /root/athena/.
#
# This is the VM equivalent of bootstrap-k8s-auth.sh: the Olympus tier has
# no Vault auth today (services read plaintext .env), so we establish
# AppRole here. Reuse this pattern for every other VM service — one
# AppRole + one policy each, scoped tight.
#
# Idempotent — safe to re-run. Requires: vault CLI authenticated
# (VAULT_ADDR / VAULT_TOKEN / VAULT_CACERT).
#
# After running, copy the printed role_id + secret_id onto athena:
#   /root/athena/vault-agent/role_id
#   /root/athena/vault-agent/secret_id      (chmod 600)
# and the root CA:
#   vault read -field=certificate pki_root/cert/ca > /root/athena/vault-agent/ca.crt

set -euo pipefail

ROLE="athena"
KV_PATH="kv/data/athena"

vault auth enable approle 2>/dev/null || true

# --- policy: read its own KV, issue its own leaf cert, nothing else ---
vault policy write "$ROLE" - <<EOF
path "${KV_PATH}" {
  capabilities = ["read"]
}

path "pki_infra/issue/internal" {
  capabilities = ["create", "update"]
  # scope the cert to this host only (node hostname is athena)
  allowed_parameters = {
    "common_name" = ["athena.bgalhardo.internal"]
    "ttl"         = []
  }
}
EOF

# --- role: periodic token, auto-renewed by the agent ---
vault write "auth/approle/role/${ROLE}" \
  token_policies="$ROLE" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0 \
  token_num_uses=0

ROLE_ID=$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id")
SECRET_ID=$(vault write -field=secret_id -f "auth/approle/role/${ROLE}/secret-id")

# --- seed the KV entry if absent (edit the real password afterwards) ---
if ! vault kv get "kv/${ROLE}" >/dev/null 2>&1; then
  vault kv put "kv/${ROLE}" \
    grafana_admin_user="admin" \
    grafana_admin_password="$(openssl rand -base64 24)"
  echo "Seeded kv/${ROLE} with a random Grafana password — 'vault kv get kv/${ROLE}' to read it."
fi

cat <<EOF

────────────────────────────────────────────────────────────
AppRole '${ROLE}' ready. Copy onto athena:

  echo '${ROLE_ID}'  > /root/athena/vault-agent/role_id
  echo '${SECRET_ID}' > /root/athena/vault-agent/secret_id
  chmod 600 /root/athena/vault-agent/secret_id

  vault read -field=certificate pki_root/cert/ca \\
    > /root/athena/vault-agent/ca.crt

secret_id_ttl=0 → non-expiring bootstrap credential. It is scoped to the
'${ROLE}' policy only (read one KV path + issue one cert). Rotate it with
'vault write -f auth/approle/role/${ROLE}/secret-id' and re-copy.
────────────────────────────────────────────────────────────
EOF
