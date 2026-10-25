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
set -euo pipefail

OUT="${AI_KUBECONFIG:-$HOME/.kube/ai-readonly.kubeconfig}"
DURATION="${AI_TOKEN_DURATION:-8h}"
CONTEXT="crypto-wallet-ai-readonly"

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
expiry=$(python3 -c '
import sys, json, base64, datetime
payload = sys.stdin.read().split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
print(datetime.datetime.fromtimestamp(claims["exp"]).strftime("%Y-%m-%d %H:%M"))
' <<<"$token" || echo "unknown")

echo "Wrote ${OUT} (context ${CONTEXT}, token expires ${expiry})"
echo "Check: KUBECONFIG=${OUT} kubectl auth can-i --list"
