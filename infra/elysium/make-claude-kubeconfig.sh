#!/usr/bin/env bash
# Builds a scoped, read-only kubeconfig for Claude Code (or any automation),
# so it never uses the human cluster-admin context.
#
# The identity itself is declared in kubernetes/20-infra-wiring/rbac-claude.yaml
# and applied by Flux — this script only mints the kubeconfig from it.
#
# Run as a subprocess, never `source` it: set -e in a sourced script kills your
# shell. Requires an admin kubeconfig (yours) to read the token Secret once.
#
# Output is gitignored (.claude/secrets/*).

set -euo pipefail

NS=automation
SA=claude
SECRET=claude-token
OUT="$(git rev-parse --show-toplevel)/.claude/secrets/kube-claude.yaml"
SERVER="${SERVER:-https://192.168.1.180:6443}"   # the control-plane VIP

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

if ! kubectl get sa "$SA" -n "$NS" >/dev/null 2>&1; then
  echo "ServiceAccount $NS/$SA not found — has Flux applied rbac-claude.yaml yet?" >&2
  exit 1
fi

TOKEN=$(kubectl get secret "$SECRET" -n "$NS" -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl get secret "$SECRET" -n "$NS" -o jsonpath='{.data.ca\.crt}')   # already base64

[ -n "$TOKEN" ] || { echo "token empty — the Secret may not be populated yet" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: elysium
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
contexts:
- name: elysium-claude
  context:
    cluster: elysium
    user: claude
current-context: elysium-claude
users:
- name: claude
  user:
    token: ${TOKEN}
EOF
chmod 600 "$OUT"

echo "wrote $OUT"
echo
echo "Verify the guardrail actually holds:"
echo "  KUBECONFIG=$OUT kubectl get pods -A            # should work"
echo "  KUBECONFIG=$OUT kubectl get secrets -A         # should be Forbidden"
echo "  KUBECONFIG=$OUT kubectl delete pod -n ai foo   # should be Forbidden"
echo "  KUBECONFIG=$OUT kubectl auth can-i --list      # full picture"
