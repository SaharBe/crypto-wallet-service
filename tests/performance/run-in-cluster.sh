#!/usr/bin/env bash
# Runs a k6 script from this directory as an ephemeral Pod inside the
# cluster, so load is generated in-cluster (no local port-forward bottleneck
# skewing latency numbers) and hits the frontend Service exactly as real
# traffic would. Invoked by `make test-load K6_MODE=cluster` — see the
# root Makefile.
set -euo pipefail

SCRIPT="${1:?usage: run-in-cluster.sh <script.js> (load-test.js|spike-test.js|kafka-pipeline-stress.js)}"
NAMESPACE="${K8S_NAMESPACE:-crypto-wallet-app}"
BASE_URL="${BASE_URL:-http://frontend.${NAMESPACE}.svc.cluster.local}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$DIR/$SCRIPT" ]; then
  echo "❌ Unknown k6 script: $SCRIPT (not found in $DIR)" >&2
  exit 1
fi

CM_NAME="k6-scripts"
POD_NAME="k6-$(basename "$SCRIPT" .js)-$(date +%s)"

# Stream metrics into Prometheus's remote-write receiver (enabled in
# k8s/apps/monitoring-app.yaml) so the run shows up live on the
# "Crypto Wallet - Performance & Load" Grafana dashboard, tagged
# testid=<pod name> for that dashboard's test-id picker. Set
# K6_PROMETHEUS_RW_SERVER_URL='' to skip pushing (summary-only, as before).
PROM_RW_URL="${K6_PROMETHEUS_RW_SERVER_URL-http://monitoring-stack-kube-prom-prometheus.monitoring.svc.cluster.local:9090/api/v1/write}"
K6_ARGS='"run", "--quiet"'
K6_ENV='{"name": "BASE_URL", "value": "'"$BASE_URL"'"}'
if [ -n "$PROM_RW_URL" ]; then
  K6_ARGS+=', "-o", "experimental-prometheus-rw", "--tag", "testid='"$POD_NAME"'"'
  K6_ENV+=', {"name": "K6_PROMETHEUS_RW_SERVER_URL", "value": "'"$PROM_RW_URL"'"}'
  K6_ENV+=', {"name": "K6_PROMETHEUS_RW_TREND_STATS", "value": "p(95),p(99),avg,max"}'
  echo "📈 Pushing metrics to $PROM_RW_URL (testid=$POD_NAME)"
fi

from_file_args=()
for f in "$DIR"/*.js; do
  from_file_args+=(--from-file="$f")
done

echo "📦 Publishing k6 scripts as ConfigMap '$CM_NAME' in namespace '$NAMESPACE'..."
kubectl create configmap "$CM_NAME" -n "$NAMESPACE" \
  "${from_file_args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

cleanup() {
  kubectl delete configmap "$CM_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "🚀 Running $SCRIPT as ephemeral Pod '$POD_NAME' against $BASE_URL..."
kubectl run "$POD_NAME" \
  --namespace "$NAMESPACE" \
  --image=grafana/k6:latest \
  --restart=Never \
  --rm -i \
  --overrides="$(cat <<EOF
{
  "spec": {
    "restartPolicy": "Never",
    "containers": [{
      "name": "k6",
      "image": "grafana/k6:latest",
      "args": [$K6_ARGS, "/scripts/$SCRIPT"],
      "env": [$K6_ENV],
      "volumeMounts": [{"name": "scripts", "mountPath": "/scripts"}],
      "resources": {
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "1", "memory": "512Mi"}
      }
    }],
    "volumes": [{"name": "scripts", "configMap": {"name": "$CM_NAME"}}]
  }
}
EOF
)"
