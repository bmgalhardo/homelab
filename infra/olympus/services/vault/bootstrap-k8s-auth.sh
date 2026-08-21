#!/usr/bin/env bash
# Configures Vault's kubernetes auth method for the hal9000 cluster.
#
# Vault runs as a plain Docker container on Apollo (see docker-compose.yml),
# not inside Kubernetes, so it has no in-pod service account to fall back
# on for validating login tokens. auth/kubernetes/config MUST carry an
# explicit token_reviewer_jwt (from the vault-auth SA below) or every
# kubernetes-auth login fails with a generic 403 permission denied — this
# is what happened from 2025-12-12 to 2026-08-21: the config was rewritten
# (vault write replaces the whole object) without that field, silently
# dropping it, breaking cert-manager's `vault` Issuer and every
# VaultSecretsOperator secret in the cluster for ~8 months.
#
# Idempotent — safe to re-run. Requires: vault CLI authenticated
# (VAULT_ADDR/VAULT_TOKEN/VAULT_CACERT), kubectl pointed at hal9000.

set -euo pipefail

K8S_HOST="https://192.168.1.180:6443"
REVIEWER_SA="vault-auth"
REVIEWER_NS="vault-secrets-operator"

REVIEWER_JWT=$(kubectl get secret "$REVIEWER_SA" -n "$REVIEWER_NS" -o jsonpath='{.data.token}' | base64 -d)
KCA=$(kubectl get secret "$REVIEWER_SA" -n "$REVIEWER_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)

vault auth enable kubernetes 2>/dev/null || true

vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$KCA" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_iss_validation=true

# --- cert-manager (Issuer "vault" in ns system, kubernetes/system/issuer-vault.yml) ---
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

# --- vault-secrets-operator (VaultConnection "default", kubernetes/vault-secrets-operator/) ---
vault policy write vault-secrets-operator - <<'EOF'
path "kv/data/hal9000/*" {
   capabilities = ["read", "list"]
}
EOF

vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names=default \
  bound_service_account_namespaces="*" \
  policies=vault-secrets-operator \
  ttl=24h

echo "Vault kubernetes auth configured."

# --- vault-ca Secret (vault-secrets-operator ns): root CA cert VSO's
# "default" VaultConnection uses to trust Vault's own TLS listener.
# Chicken-and-egg — VSO can't sync this one via a VaultStaticSecret like
# it does everywhere else (kv/hal9000/ca, see kubernetes/system/
# issuer-vault.yml for the system-ns copy cert-manager uses), since it
# needs this CA before it can talk to Vault at all. Not auth-related, but
# needs a manual refresh here if the root CA ever rotates.
ROOT_CA=$(vault read -field=certificate pki_root/cert/ca)

kubectl create secret generic vault-ca --from-literal=ca.crt="$ROOT_CA" \
  -n vault-secrets-operator --dry-run=client -o yaml | kubectl apply -f -

echo "vault-ca Secret refreshed in vault-secrets-operator namespace."
