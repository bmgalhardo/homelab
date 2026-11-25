#!/usr/bin/env bash
# Build gaia from its secrets archive (see secrets.sh). Interactive: age asks
# for the passphrase.
#
#   ./bootstrap.sh install ARCHIVE MAINT_IP  # VM in maintenance mode -> running cluster
#   ./bootstrap.sh finish ARCHIVE            # the part after apply-config (safe to re-run)
#   ./bootstrap.sh creds ARCHIVE             # (re)write talosconfig + kubeconfig only
#
# Admin credentials go to ~/.kube/gaia and ~/.talos/gaia (mode 600):
#   export KUBECONFIG=~/.kube/config:~/.kube/gaia TALOSCONFIG=~/.talos/gaia

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
NODE=192.168.1.172
ENDPOINT=https://$NODE:6443
KUBE_CREDS="$HOME/.kube/gaia"
TALOS_CREDS="$HOME/.talos/gaia"

render() {  # $1 archive -> $WORK/{bundle,controlplane.yaml,talosconfig}
  WORK=$(umask 077 && mktemp -d "/run/user/$(id -u)/gaia-build.XXXX")
  trap 'rm -rf "$WORK"' EXIT
  "$HERE/secrets.sh" unpack "$1" "$WORK/bundle" >/dev/null
  {
    printf 'apiVersion: v1alpha1\nkind: TrustedRootsConfig\nname: homelab-ca\ncertificates: |-\n'
    sed 's/^/  /' "$HERE/../ca/root-ca.crt"
  } > "$WORK/ca.yaml"
  talosctl gen config gaia "$ENDPOINT" \
    --with-secrets "$WORK/bundle/talos-secrets.yaml" \
    --config-patch @"$HERE/talos/patch.yaml" \
    --config-patch @"$WORK/ca.yaml" \
    --output-types controlplane,talosconfig \
    --with-docs=false --with-examples=false \
    -o "$WORK" >/dev/null
  talosctl validate --mode metal --strict -c "$WORK/controlplane.yaml" >/dev/null
  talosctl --talosconfig "$WORK/talosconfig" config endpoint "$NODE"
  talosctl --talosconfig "$WORK/talosconfig" config node "$NODE"
}

save_creds() {
  (umask 077 && mkdir -p "$(dirname "$KUBE_CREDS")" "$(dirname "$TALOS_CREDS")")
  install -m 600 "$WORK/talosconfig" "$TALOS_CREDS"
  talosctl --talosconfig "$TALOS_CREDS" kubeconfig --force "$KUBE_CREDS" >/dev/null
  chmod 600 "$KUBE_CREDS"
  echo "credentials in $KUBE_CREDS and $TALOS_CREDS"
}

wait_for() {  # $1 description, rest: command
  local what=$1; shift
  printf 'waiting for %s' "$what"
  for _ in $(seq 1 90); do
    if "$@" >/dev/null 2>&1; then echo " ok"; return 0; fi
    printf .; sleep 10
  done
  echo " timed out" >&2; exit 1
}

install_cluster() {
  local archive=${1:?archive} maint=${2:?maintenance-mode IP}
  render "$archive"

  echo "disks on $maint:"
  talosctl get disks --insecure -n "$maint"
  read -rp "Install to /dev/sda, local-path on the other disk. Continue? [y/N] " ok
  [ "$ok" = y ]

  talosctl apply-config --insecure -n "$maint" -f "$WORK/controlplane.yaml"
  finish
}

etcd_bootstrapped() {  # bootstrap once; true when etcd is bootstrapped
  local out
  out=$("${T[@]}" bootstrap 2>&1) && return 0
  case "$out" in *AlreadyExists*|*"already bootstrapped"*) return 0 ;; esac
  return 1  # e.g. FailedPrecondition while the node installs and reboots
}

finish() {  # after apply-config; expects render() done
  T=(talosctl --talosconfig "$WORK/talosconfig")
  wait_for "etcd bootstrap on $NODE" etcd_bootstrapped
  save_creds
  K=(kubectl --kubeconfig "$KUBE_CREDS")
  wait_for "Kubernetes API" "${K[@]}" get --raw /readyz
  "${K[@]}" apply -f "$WORK/bundle/k8s/"
  wait_for "node Ready" "${K[@]}" wait --for=condition=Ready node/gaia --timeout=10s
  echo "gaia is up. Next: flux bootstrap (README)."
}

case "${1:-}" in
  install) shift; install_cluster "$@" ;;
  finish)  shift; render "${1:?archive}"; finish ;;
  creds)   shift; render "${1:?archive}"; save_creds ;;
  *)       sed -n '2,10p' "$0" >&2; exit 1 ;;
esac
