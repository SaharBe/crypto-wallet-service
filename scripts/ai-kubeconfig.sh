#!/usr/bin/env bash
# Writes a kubeconfig for the ai-readonly ServiceAccount (k8s/apps/ai-ops/rbac.yaml)
# that Radar uses for AI-assisted ops (PLAT-504). Run as the operator, with
# the current kubectl context pointing at the cluster: that identity only
# mints the token, it doesn't end up in the file.
#
# The file holds this ONE context and nothing else. Radar can switch between
# the contexts of the kubeconfig it was started with, so pointing it at
# ~/.kube/config would put the operator's admin context one click (or one
# MCP call) away.
#
# The token is short-lived (`kubectl create token`), not a long-lived
# ServiceAccount token Secret: re-run this when it expires.
#
# --if-needed (used by `make radar`): keep the existing file when its token
# is still valid on the current cluster, otherwise mint a new one. That
# covers an expired token and a rebuilt cluster (`make down` + `make up`:
# new endpoint/CA, and a new ServiceAccount that rejects the old token).
# Minting at Radar start, rather than in bootstrap.sh, starts the token's
# lifetime when it's actually used.
set -euo pipefail

OUT="${AI_KUBECONFIG:-$HOME/.kube/ai-readonly.kubeconfig}"
DURATION="${AI_TOKEN_DURATION:-8h}"
CONTEXT="crypto-wallet-ai-readonly"
# A token closer to expiry than this is replaced, so Radar doesn't lose
# access a few minutes into a session.
MIN_REMAINING_SECONDS=1800
# How long to wait for ArgoCD to create the ServiceAccount on a fresh cluster
SA_WAIT_SECONDS="${AI_SA_WAIT_SECONDS:-600}"

# Prints a JWT's "exp" claim (epoch seconds), or nothing if it can't be read
token_exp() {
  python3 -c '
import sys, json, base64
try:
    payload = sys.stdin.read().strip().split(".")[1]
    print(json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["exp"])
except Exception:
    pass
'
}

if [[ "${1:-}" == "--if-needed" && -f "$OUT" ]]; then
  existing=$(kubectl --kubeconfig "$OUT" config view --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)
  exp=$(token_exp <<<"$existing")
  # The expiry check alone isn't enough: after a cluster rebuild the token
  # can be unexpired but belong to a ServiceAccount that no longer exists.
  # `auth whoami` asks the cluster in the file whether it still accepts it.
  if [[ -n "$exp" ]] && (( exp - $(date +%s) > MIN_REMAINING_SECONDS )) \
    && kubectl --kubeconfig "$OUT" --request-timeout=10s auth whoami >/dev/null 2>&1 </dev/null; then
    echo "Reusing ${OUT} (token valid until $(date -d "@$exp" '+%Y-%m-%d %H:%M'))"
    exit 0
  fi
  echo "${OUT} is expired or doesn't match the current cluster, minting a new token..."
fi

# On a fresh cluster ArgoCD creates the ServiceAccount a few minutes after
# `make up` (ApplicationSet element `ai-ops`), so wait for it rather than fail
deadline=$(( $(date +%s) + SA_WAIT_SECONDS ))
# stdin closed so kubectl can never sit on an invisible credentials prompt;
# the error is kept so a timeout says why (not found vs. no cluster access)
until err=$(kubectl get serviceaccount ai-readonly -n ai-ops --request-timeout=10s 2>&1 >/dev/null </dev/null); do
  if (( $(date +%s) >= deadline )); then
    echo "ServiceAccount ai-ops/ai-readonly not available after ${SA_WAIT_SECONDS}s." >&2
    echo "Last error: ${err}" >&2
    echo "Check: kubectl get application ai-ops -n argocd" >&2
    exit 1
  fi
  echo "Waiting for ArgoCD to create ServiceAccount ai-ops/ai-readonly..."
  sleep 15
done

server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ca=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
token=$(kubectl create token ai-readonly -n ai-ops --duration "$DURATION")

mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CONTEXT}
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: ai-readonly
    user:
      token: ${token}
contexts:
  - name: ${CONTEXT}
    context:
      cluster: ${CONTEXT}
      user: ai-readonly
current-context: ${CONTEXT}
EOF

# The API server may cap the requested duration, so report the real expiry
exp=$(token_exp <<<"$token")
expiry=$([[ -n "$exp" ]] && date -d "@$exp" '+%Y-%m-%d %H:%M' || echo "unknown")

echo "Wrote ${OUT} (context ${CONTEXT}, token expires ${expiry})"
echo "Check: KUBECONFIG=${OUT} kubectl auth can-i --list"
