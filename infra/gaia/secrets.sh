#!/usr/bin/env bash
# gaia's bootstrap secrets, kept out of git: one passphrase-encrypted archive
# in /odin/backup/gaia/ on Hades. Run in an interactive terminal (age asks for
# the passphrase).
#
#   ./secrets.sh unpack FILE DIR   # decrypt FILE into DIR (created, mode 700)
#   ./secrets.sh pack DIR          # encrypt DIR, copy to Hades
#
# To change a secret: unpack, edit, pack, delete DIR.
#
# Archive layout:
#   talos-secrets.yaml   talosctl gen secrets (input to talosctl gen config)
#   k8s/*.yaml           Namespaces + Secrets, applied once at bootstrap

set -euo pipefail

HADES_DIR=/odin/backup/gaia

pack() {
  local dir=${1:?dir} name out
  [ -s "$dir/talos-secrets.yaml" ] && [ -d "$dir/k8s" ] ||
    { echo "$dir: expected talos-secrets.yaml and k8s/" >&2; exit 1; }
  echo "archive contents:"
  (cd "$dir" && find . -type f | sort | sed 's/^/  /')

  name="gaia-secrets-$(date +%Y%m%d-%H%M).age"
  out=$(umask 077 && mktemp)
  trap 'rm -f "$out"' EXIT
  tar -C "$dir" -c . | age -p > "$out"

  ssh -o BatchMode=yes hades "umask 077; mkdir -p $HADES_DIR; cat > $HADES_DIR/$name; sha256sum $HADES_DIR/$name" < "$out"
  echo "local sha256: $(sha256sum "$out" | cut -d' ' -f1)"
}

unpack() {
  local file=${1:?archive} dir=${2:?target dir}
  (umask 077 && mkdir -p "$dir")
  age -d "$file" | tar -C "$dir" -x
  echo "decrypted into $dir; delete it when done"
}

case "${1:-}" in
  pack)   shift; pack "$@" ;;
  unpack) shift; unpack "$@" ;;
  *)      sed -n '2,13p' "$0" >&2; exit 1 ;;
esac
