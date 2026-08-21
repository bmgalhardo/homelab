#!/bin/sh

apk add --no-cache jq curl

echo [$(date)] Starting Vault unsealer...

while true; do
  vault_status=$(curl -s "$VAULT_ADDR/v1/sys/seal-status" | jq -r '.sealed')

  if [ -z "$vault_status" ]; then
    echo [$(date)] Vault unreachable, retrying in $ERROR_DELAY seconds...
    sleep "$ERROR_DELAY"
    continue
  fi

  if [ "$vault_status" = "false" ]; then
    sleep "$CHECK_INTERVAL"
    continue
  fi

  echo [$(date)] Vault is sealed. Attempting unseal...

  result=$(curl -s --request PUT --data "{\"key\": \"$VAULT_UNSEAL_KEY\"}" "$VAULT_ADDR/v1/sys/unseal")
  sealed=$(echo "$result" | jq -r '.sealed')

  if [ "$sealed" = "false" ]; then
    echo [$(date)] Vault successfully unsealed.
  else
    echo [$(date)] Failed to unseal Vault. Retrying in $ERROR_DELAY seconds...
    sleep "$ERROR_DELAY"
  fi
done
