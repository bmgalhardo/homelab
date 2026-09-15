#!/usr/bin/env bash
# Vault-side setup for a service's Vault Agent (AppRole auth).
#
# This script talks ONLY to Vault. It never touches the target node — which is
# also why the node can never run it: a node's own AppRole token is denied on
# auth/approle/role/<role> by design. Run it from wherever your Vault CLI is
# authenticated.
#
# The objects it creates (policy, AppRole, KV entry) live in Vault's raft store
# and survive any node rebuild. Reprovisioning a node does NOT require re-running
# this — only re-delivering a secret_id (see --secret-id-only).
#
# Idempotent. Requires: vault CLI authenticated (VAULT_ADDR / VAULT_TOKEN).
#
#   ./approle-bootstrap.sh roles/athena.env
#   ./approle-bootstrap.sh roles/athena.env --print-policy   # no writes
#   ./approle-bootstrap.sh roles/athena.env --secret-id-only # rotate/redeliver
#
# Run as a subprocess, never `source` it: set -e in a sourced script kills
# your shell.

set -euo pipefail

ROLEFILE="${1:-}"
MODE="${2:-apply}"

if [ -z "$ROLEFILE" ] || [ ! -f "$ROLEFILE" ]; then
  echo "usage: $0 roles/<service>.env [--print-policy|--secret-id-only]" >&2
  echo "available:" >&2; ls "$(dirname "$0")/roles/" >&2
  exit 1
fi

# Role definitions are plain env files — see roles/README or any existing one.
KV_PATH=""; IP_SAN=""; KV_SEED=""
# shellcheck disable=SC1090
. "$ROLEFILE"

: "${ROLE:?role file must set ROLE}"
: "${COMMON_NAME:?role file must set COMMON_NAME}"

PKI_ROLE="${PKI_ROLE:-pki_infra/issue/internal}"

# ── build the policy ────────────────────────────────────────────────────────
# allowed_parameters is a strict allow-list: any parameter not named here is
# rejected at request time, so ip_sans must be listed even though it is also
# scoped by value.
build_policy() {
  if [ -n "$KV_PATH" ]; then
    printf 'path "%s" {\n  capabilities = ["read"]\n}\n\n' "$KV_PATH"
  fi
  printf 'path "%s" {\n' "$PKI_ROLE"
  printf '  capabilities = ["create", "update"]\n'
  printf '  allowed_parameters = {\n'
  printf '    "common_name" = ["%s"]\n' "$COMMON_NAME"
  [ -n "$IP_SAN" ] && printf '    "ip_sans"     = ["%s"]\n' "$IP_SAN"
  printf '    "ttl"         = []\n'
  printf '  }\n}\n'
}

if [ "$MODE" = "--print-policy" ]; then
  build_policy
  exit 0
fi

command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 1; }

# ── rotate/redeliver only: the node-rebuild path ────────────────────────────
if [ "$MODE" = "--secret-id-only" ]; then
  ROLE_ID=$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id")
  SECRET_ID=$(vault write -field=secret_id -f "auth/approle/role/${ROLE}/secret-id")
  echo "role_id:   ${ROLE_ID}"
  echo "secret_id: ${SECRET_ID}"
  echo
  echo "Any previously issued secret_id for '${ROLE}' still works until revoked:"
  echo "  vault list auth/approle/role/${ROLE}/secret-id"
  exit 0
fi

vault auth enable approle 2>/dev/null || true

build_policy | vault policy write "$ROLE" -

vault write "auth/approle/role/${ROLE}" \
  token_policies="$ROLE" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0 \
  token_num_uses=0 >/dev/null

ROLE_ID=$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id")
SECRET_ID=$(vault write -field=secret_id -f "auth/approle/role/${ROLE}/secret-id")

# ── seed KV if the role wants one and it does not exist yet ─────────────────
# Guarded: re-running never clobbers an existing password.
if [ -n "$KV_SEED" ]; then
  KV_KV="${KV_PATH#kv/data/}"
  if ! vault kv get "kv/${KV_KV}" >/dev/null 2>&1; then
    args=""
    for pair in $KV_SEED; do
      key="${pair%%=*}"; val="${pair#*=}"
      [ "$val" = "@random" ] && val="$(openssl rand -base64 24)"
      args="$args ${key}=${val}"
    done
    # shellcheck disable=SC2086
    vault kv put "kv/${KV_KV}" $args >/dev/null
    echo "Seeded kv/${KV_KV} — read it with: vault kv get kv/${KV_KV}"
  else
    echo "kv/${KV_KV} already exists — left untouched."
  fi
fi

DEPLOY_DIR="${DEPLOY_DIR:-/root/${ROLE}}"

cat <<EOF

────────────────────────────────────────────────────────────
AppRole '${ROLE}' ready. Deliver the credentials to the node:

  echo '${ROLE_ID}'   > ${DEPLOY_DIR}/vault-agent/role_id
  echo '${SECRET_ID}' > ${DEPLOY_DIR}/vault-agent/secret_id
  chmod 600 ${DEPLOY_DIR}/vault-agent/secret_id

The root CA is a committed file — no Vault round-trip needed:

  scp infra/ca/root-ca.crt <node>:${DEPLOY_DIR}/vault-agent/ca.crt

secret_id_ttl=0 → non-expiring bootstrap credential, scoped to the '${ROLE}'
policy alone. Rotate with:  $0 ${ROLEFILE} --secret-id-only
────────────────────────────────────────────────────────────
EOF
