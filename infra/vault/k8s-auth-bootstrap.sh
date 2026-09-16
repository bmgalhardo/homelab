#!/usr/bin/env bash
# Vault's kubernetes auth for elysium: auth config, cert-manager + VSO policies
# and roles, and the vault-ca Secret VSO uses to trust Vault. See README.md.
#
# Idempotent. Requires: vault CLI authenticated (VAULT_ADDR / VAULT_TOKEN),
# kubectl on the admin context, tier 1 (kubernetes/10-infra-base) applied.

set -euo pipefail

K8S_HOST="https://192.168.1.180:6443"
REVIEWER_SA="vault-auth"
REVIEWER_NS="vault-secrets-operator"
ROOT_CA="$(dirname "$0")/../ca/root-ca.crt"

REVIEWER_JWT=$(kubectl get secret "$REVIEWER_SA" -n "$REVIEWER_NS" -o jsonpath='{.data.token}' | base64 -d)
KCA=$(kubectl get secret "$REVIEWER_SA" -n "$REVIEWER_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)

vault auth enable kubernetes 2>/dev/null || true

vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$KCA" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_iss_validation=true

# --- cert-manager: Issuer "vault", kubernetes/20-infra-wiring/issuer-vault.yaml ---
vault policy write cert_manager - <<'EOF'
path "pki_cert_manager/sign/internal" {
  capabilities = ["create", "update"]
}

path "pki_cert_manager/cert/ca" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/issuer \
  bound_service_account_names=default \
  bound_service_account_namespaces=system \
  policies=cert_manager \
  ttl=20m

# --- vault-secrets-operator: VaultAuth "default", kubernetes/20-infra-wiring/vso-config.yaml ---
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
