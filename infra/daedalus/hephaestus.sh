#!/usr/bin/env bash
# Power control for hephaestus (Blender LXC on hades), run from daedalus.
#
#   ./hephaestus.sh up       # wake hades if off, start it, wait for SSH
#   ./hephaestus.sh down     # graceful shutdown (hades stays on)
#   ./hephaestus.sh status
#
# Config: $ENV_FILE (default .claude/secrets/proxmox-power.env, see the
# .example next to it). Hades itself is not powered off by this script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.claude/secrets/proxmox-power.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${PROXMOX_API_HOST:?}" "${PROXMOX_TOKEN_ID:?}" "${PROXMOX_TOKEN_SECRET:?}"
HADES_MAC="${HADES_MAC:-f0:2f:74:30:76:71}"
NODE="${NODE:-hades}"
VM_NAME="${VM_NAME:-hephaestus}"
SSH_HOST="${SSH_HOST:-hephaestus}"
BROADCAST="${BROADCAST:-192.168.1.255}"
NODE_TIMEOUT="${NODE_TIMEOUT:-300}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"

api() {
  local method="$1" path="$2"
  curl -fsS -X "$method" \
    -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_SECRET" \
    "$PROXMOX_API_HOST/api2/json$path"
}

log() { echo "[$(date +%T)] $*" >&2; }

node_status() {
  api GET /nodes | jq -r --arg n "$NODE" '.data[] | select(.node == $n) | .status'
}

vm_field() {
  api GET /cluster/resources \
    | jq -r --arg n "$VM_NAME" --arg node "$NODE" --arg f "$1" \
        '.data[] | select((.type == "qemu" or .type == "lxc") and .name == $n and .node == $node) | .[$f]'
}

wake() {
  python3 - "$HADES_MAC" "$BROADCAST" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", "").replace("-", ""))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(b"\xff" * 6 + mac * 16, (sys.argv[2], 9))
PY
}

wait_until() {
  local timeout="$1" what="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    (( SECONDS < deadline )) || { log "timed out waiting for $what"; return 1; }
    sleep 5
  done
}

node_online() { [ "$(node_status)" = online ]; }
vm_known()    { [ -n "$(vm_field vmid)" ]; }
ssh_ready()   { ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" true 2>/dev/null; }

wait_task() {
  local upid="$1" status
  while :; do
    status=$(api GET "/nodes/$NODE/tasks/$upid/status" | jq -r '.data.status + " " + (.data.exitstatus // "")')
    case "$status" in
      "stopped OK") return 0 ;;
      stopped*)     log "task failed: ${status#stopped }"; return 1 ;;
    esac
    sleep 2
  done
}

vm_action() {
  local vmid type upid
  vmid=$(vm_field vmid)
  type=$(vm_field type)
  upid=$(api POST "/nodes/$NODE/$type/$vmid/status/$1" | jq -r .data)
  wait_task "$upid"
}

cmd_up() {
  if ! node_online; then
    log "$NODE offline, sending WoL to $HADES_MAC"
    wake
    wait_until "$NODE_TIMEOUT" "$NODE online" node_online
  fi
  wait_until 60 "$VM_NAME in cluster resources" vm_known

  if [ "$(vm_field status)" != running ]; then
    log "starting $VM_NAME ($(vm_field vmid))"
    vm_action start
  fi
  wait_until "$SSH_TIMEOUT" "ssh $SSH_HOST" ssh_ready
  log "$VM_NAME ready"
}

cmd_down() {
  if ! node_online; then log "$NODE offline"; return 0; fi
  if [ "$(vm_field status)" = running ]; then
    log "shutting down $VM_NAME"
    vm_action shutdown
  fi
  log "$VM_NAME stopped"
}

cmd_status() {
  local ns; ns=$(node_status)
  echo "$NODE: ${ns:-unknown}"
  [ "$ns" = online ] && echo "$VM_NAME: $(vm_field status) (vmid $(vm_field vmid))"
  return 0
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)      echo "usage: $0 up|down|status" >&2; exit 1 ;;
esac
