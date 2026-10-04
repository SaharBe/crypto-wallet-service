// Shared helpers for the k6 scripts in this directory. Kept dependency-free
// (no jslib/npm imports) so scripts also run unmodified from the ConfigMap
// mounted by run-in-cluster.sh, with no bundling step.

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// BASE_URL defaults to the ingress-nginx port-forward (`make ingress-forward`,
// http://localhost:8080), not a Service name, so there's no DNS to tell
// ingress-nginx which virtual host to route on. The wallet Ingress
// (k8s/apps/ingress/wallet-ingress.yaml) only matches `host: wallet.local`,
// so every request needs that explicit Host header or ingress-nginx 404s.
// Override with HOST_HEADER=<value>, or HOST_HEADER='' to send none — e.g.
// when pointing BASE_URL at the frontend Service directly (run-in-cluster.sh,
// or `kubectl port-forward svc/frontend`), where the frontend's nginx
// (server_name _) and backends ignore Host entirely, so leaving the default
// in place there is harmless too.
const HOST_HEADER = __ENV.HOST_HEADER !== undefined ? __ENV.HOST_HEADER : 'wallet.local';

// Merges the shared Host header (if any) into a request's own headers.
export function withHost(headers = {}) {
  return HOST_HEADER ? { ...headers, Host: HOST_HEADER } : headers;
}

const COINS = ['BTC', 'ETH', 'SOL', 'USDT'];
const ACTIONS = ['buy', 'sell'];

export function randomUserId(prefix) {
  return `${prefix}-vu${__VU}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

export function randomCoin() {
  return COINS[Math.floor(Math.random() * COINS.length)];
}

// 'buy' only, by default: consumer.js applies the action as a signed delta
// on top of whatever the user already holds, so a random 'sell' against a
// fresh (zero-balance) test user is a legal but meaningless negative
// balance. Buys keep generated load representative of the common case.
export function randomAction() {
  return ACTIONS[0];
}

export function randomAmount(min = 0.001, max = 2) {
  return +(Math.random() * (max - min) + min).toFixed(6);
}

export function randomSleep(minSeconds, maxSeconds) {
  return Math.random() * (maxSeconds - minSeconds) + minSeconds;
}
