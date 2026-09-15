#!/usr/bin/env bash
# Put an SSH public key on every host in the fleet. Idempotent.
#
#   ./distribute-key.sh              # install
#   ./distribute-key.sh --dry-run    # show what would be installed
#   ./distribute-key.sh --verify     # just check who answers
#
# WHY this exists: the hosts are all directly reachable on port 22 — no VLAN,
# no firewall between workstation and fleet. Routing through a bastion bought
# no isolation, only a single point of failure: when hermes (DNS + LB + the
# keyring) goes down you would lose DNS *and* the ability to log in and fix
# it. Keys direct removes that coupling; hermes keeps its keyring as a second
# independent path.
#
# ssh-copy-id does the whole job — creates ~/.ssh, fixes modes, and skips keys
# already present — so there is nothing to hand-roll here.

set -euo pipefail

KEYFILE="${KEYFILE:-$HOME/.ssh/id_ed25519.pub}"
MODE="${1:-apply}"

# ── the fleet ───────────────────────────────────────────────────────────────
# Kept in sync with .claude/context/network.md. root-login Linux hosts only.
#
# Deliberately absent:
#   192.168.1.180  k8s control plane — Talos runs no sshd (connection
#                  refused, by design). Use talosctl/omnictl.
#   192.168.1.1    UDM Pro — UniFi manages its own key material.
#   192.168.1.89   qdevice LXC — has no key from anywhere, not even hermes.
#                  Reach it from Apollo via `pct enter <ctid>` to seed one.
HOSTS=$(cat <<'EOF'
192.168.1.196 athena
192.168.1.197 apollo
192.168.1.198 hades
192.168.1.199 hermes
192.168.1.171 omni
192.168.1.173 vault
192.168.1.174 authentik
192.168.1.177 postgres
EOF
)

[ -f "$KEYFILE" ] || { echo "no public key at $KEYFILE" >&2; exit 1; }

verify() {
  echo "Direct access from this workstation:"
  # -n matters: without it ssh consumes the loop's stdin and the remaining
  # hosts are silently skipped.
  echo "$HOSTS" | while read -r ip name; do
    [ -z "$ip" ] && continue
    printf "  %-14s %-10s " "$ip" "$name"
    timeout 6 ssh -n -o ConnectTimeout=4 -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new "root@$ip" true 2>/dev/null \
      && echo OK || echo no
  done
}

[ "$MODE" = "--verify" ] && { verify; exit 0; }

# ssh-copy-id -n is its own dry-run.
COPY_OPTS=(-i "$KEYFILE" -o BatchMode=yes -o ConnectTimeout=5
           -o StrictHostKeyChecking=accept-new)
[ "$MODE" = "--dry-run" ] && COPY_OPTS+=(-n)

echo "$HOSTS" | while read -r ip name; do
  [ -z "$ip" ] && continue
  printf "  %-14s %-10s " "$ip" "$name"
  if out=$(ssh-copy-id "${COPY_OPTS[@]}" "root@$ip" 2>&1); then
    case "$out" in
      *"already exist"*) echo "already present" ;;
      *)                 echo "ok" ;;
    esac
  else
    echo "FAILED — $(echo "$out" | tail -1)"
  fi
done

echo
verify

cat <<'EOF'

If a host shows "no": it has no key yet and cannot be reached directly. Seed
it from a host that can reach it 
EOF
