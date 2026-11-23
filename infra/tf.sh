#!/usr/bin/env bash
# Terraform for a Talos stack, with the Proxmox token only in this process.
#
#   infra/tf.sh <stack> <terraform args...>   # stack: elysium | gaia
#   infra/tf.sh gaia plan
#
# Token: Vault kv/infra/proxmox-terraform (token_id, token_secret), read with
# your own Vault login. If Vault can't be read, it asks (paste from Bitwarden).

set -euo pipefail

INFRA=$(cd "$(dirname "$0")" && pwd)
stack=${1:-}
dir="$INFRA/$stack/terraform"
[ -n "$stack" ] && [ -f "$dir/main.tf" ] || { sed -n '2,8p' "$0" >&2; exit 1; }
shift

export VAULT_ADDR="${VAULT_ADDR:-https://vault.bgalhardo.internal}"
export VAULT_CACERT="${VAULT_CACERT:-$INFRA/ca/root-ca.crt}"

if id=$(vault kv get -mount=kv -field=token_id infra/proxmox-terraform 2>/dev/null) &&
   secret=$(vault kv get -mount=kv -field=token_secret infra/proxmox-terraform 2>/dev/null); then
  :
else
  echo "Vault unavailable: enter the Proxmox Terraform token (Bitwarden)." >&2
  read -rp "token id (user@realm!name): " id
  read -rsp "token secret: " secret; echo >&2
fi

PM_API_URL=https://proxmox.bgalhardo.internal/api2/json \
PM_API_TOKEN_ID=$id PM_API_TOKEN_SECRET=$secret \
  exec terraform -chdir="$dir" "$@"
