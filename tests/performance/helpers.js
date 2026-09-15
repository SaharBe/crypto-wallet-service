// Shared helpers for the k6 scripts in this directory. Kept dependency-free
// (no jslib/npm imports) so scripts also run unmodified from the ConfigMap
// mounted by run-in-cluster.sh, with no bundling step.

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

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
