#!/usr/bin/env bash
# End-to-end check of the local docker compose stack (`make local-smoke`).
#
# Exercises the same path a browser does, entirely through the frontend's
# nginx proxy:
#   POST /api/order/orders -> order-service -> Kafka (crypto-orders)
#     -> wallet-service consumer -> Postgres (wallets)
#   GET  /api/wallet/balance/:userId  <- reads it back
#
# Uses a unique userId per run, so it is safe to re-run against existing data.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; . ./.env; set +a; fi
BASE="http://localhost:${FRONTEND_HOST_PORT:-8088}"
USER_ID="smoke-$(date +%s)-$$"
TIMEOUT="${SMOKE_TIMEOUT:-60}"

fail() { echo "❌ $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

# 0. Schema drift guard: the local init SQL must match the k8s ConfigMap.
k8s_sql=$(sed -n '/init-schema.sql: |/,$p' k8s/components/postgres-init-configmap.yaml \
  | tail -n +2 | sed 's/^    //')
local_sql=$(grep -v '^-- Local copy\|^-- Keep the two in sync' local-dev/postgres-init/01-init-schema.sql)
[ "$k8s_sql" = "$local_sql" ] \
  || fail "local-dev/postgres-init/01-init-schema.sql has drifted from k8s/components/postgres-init-configmap.yaml"
ok "init schema matches k8s/components/postgres-init-configmap.yaml"

# 1. Every service reachable through the frontend proxy.
for path in /healthz /api/wallet/health /api/order/health; do
  curl -fsS --max-time 5 "$BASE$path" >/dev/null || fail "GET $path failed (is the stack up? make local-up)"
  ok "GET $path"
done
curl -fsS --max-time 5 "$BASE/api/wallet/" | grep -q '"database":"connected"' \
  || fail "wallet-service reports Postgres disconnected"
ok "wallet-service -> Postgres connected"

# 2. Place an order (order-service -> Kafka).
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$BASE/api/order/orders" \
  -H 'Content-Type: application/json' \
  -d "{\"userId\":\"$USER_ID\",\"coin\":\"btc\",\"amount\":1.5,\"action\":\"buy\"}")
[ "$code" = "202" ] || fail "POST /api/order/orders returned $code, expected 202"
ok "POST /api/order/orders accepted (userId=$USER_ID)"

# 3. Wait for the wallet-service consumer to apply it to Postgres.
deadline=$((SECONDS + TIMEOUT))
until body=$(curl -fsS --max-time 5 "$BASE/api/wallet/balance/$USER_ID") \
      && echo "$body" | grep -q '"coin":"BTC","amount":"1.50000000"'; do
  [ "$SECONDS" -lt "$deadline" ] || fail "balance not updated after ${TIMEOUT}s; last response: ${body:-none}"
  sleep 2
done
ok "balance reflected via Kafka consumer: $body"

echo "🎉 Local end-to-end smoke test passed."
