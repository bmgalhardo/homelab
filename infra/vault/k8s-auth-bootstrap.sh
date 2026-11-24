#!/usr/bin/env bash
# Vault's kubernetes auth for one cluster: auth config, cert-manager + VSO
# policies and roles, and the vault-ca Secret VSO uses to trust Vault. See README.md.
#
#   infra/vault/k8s-auth-bootstrap.sh elysium   # auth/kubernetes
#   infra/vault/k8s-auth-bootstrap.sh gaia      # auth/kubernetes-gaia
#
# Idempotent. Requires: vault CLI authenticated (VAULT_ADDR / VAULT_TOKEN),
# kubectl on that cluster's admin context, its tier 1 (kubernetes/<cluster>/10-infra-base) applied.

set -euo pipefail

case "${1:-}" in
  elysium) K8S_HOST="https://192.168.1.180:6443" MOUNT=kubernetes ISSUER_NS=system ;;
  gaia)    K8S_HOST="https://192.168.1.172:6443" MOUNT=kubernetes-gaia ISSUER_NS=postgres ;;
  *) sed -n '2,9p' "$0" >&2; exit 1 ;;
esac
CLUSTER=$1
REVIEWER_SA="vault-auth"
REVIEWER_NS="vault-secrets-operator"
ROOT_CA="$(dirname "$0")/../ca/root-ca.crt"

REVIEWER_JWT=$(kubectl get secret "$REVIEWER_SA" -n "$REVIEWER_NS" -o jsonpath='{.data.token}' | base64 -d)
KCA=$(kubectl get secret "$REVIEWER_SA" -n "$REVIEWER_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)

vault auth enable -path="$MOUNT" kubernetes 2>/dev/null || true

vault write "auth/$MOUNT/config" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$KCA" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_iss_validation=true

# --- cert-manager: Issuer "vault" in $ISSUER_NS (elysium: 20-infra-wiring/issuer-vault.yaml,
#     gaia: 30-apps/postgres/issuer-vault.yaml) ---
vault policy write cert_manager - <<'EOF'
path "pki_cert_manager/sign/internal" {
  capabilities = ["create", "update"]
}

path "pki_cert_manager/cert/ca" {
  capabilities = ["read"]
}
EOF

vault write "auth/$MOUNT/role/issuer" \
  bound_service_account_names=default \
  bound_service_account_namespaces="$ISSUER_NS" \
  policies=cert_manager \
  ttl=20m

if [ "$CLUSTER" != elysium ]; then
  echo "Vault auth/$MOUNT configured (cert-manager only)."
  exit 0
fi

# --- vault-secrets-operator: VaultAuth "default", kubernetes/elysium/20-infra-wiring/vso-config.yaml ---
# KV v2: policies use kv/data/<path>; the CLI spelling kv/<path> grants nothing here.
vault policy write vault-secrets-operator - <<'EOF'
path "kv/data/infra/*" {
   capabilities = ["read", "list"]
}

path "kv/data/apps/*" {
   capabilities = ["read", "list"]
}
EOF

vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names=default \
  bound_service_account_namespaces="*" \
  policies=vault-secrets-operator \
  ttl=24h

echo "Vault kubernetes auth configured."

kubectl create secret generic vault-ca --from-file=ca.crt="$ROOT_CA" \
  -n vault-secrets-operator --dry-run=client -o yaml | kubectl apply -f -

echo "vault-ca Secret refreshed in vault-secrets-operator namespace."
