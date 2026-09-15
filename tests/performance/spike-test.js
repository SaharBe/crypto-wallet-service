// Sudden burst of traffic — 0 -> 300 VUs in 15 seconds — to find where the
// stack breaks and how it fails (slow, or error) rather than to pass
// cleanly. It is normal and expected for the thresholds below to fail
// during a spike test; a failed threshold here is the finding, not a bug
// in the script. Watch pod restarts / OOMKills and readiness-probe
// failures in Grafana alongside the k6 output (see Makefile `test-load`
// target for how to observe them live).
//
// Run: BASE_URL=http://localhost:8080 k6 run spike-test.js
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { BASE_URL, randomUserId, randomCoin, randomAmount, randomAction } from './helpers.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15s', target: 300 }, // sudden burst
        { duration: '1m', target: 300 },  // hold at peak
        { duration: '15s', target: 0 },   // sudden drop
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<200'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const userId = randomUserId('spike');

  group('get_balance', () => {
    const res = http.get(`${BASE_URL}/api/wallet/balance/${userId}`, {
      tags: { name: 'get_balance' },
    });
    check(res, { 'get_balance status is 200': (r) => r.status === 200 });
  });

  group('place_order', () => {
    const payload = JSON.stringify({
      userId,
      coin: randomCoin(),
      amount: randomAmount(),
      action: randomAction(),
    });
    const res = http.post(`${BASE_URL}/api/order/orders`, payload, {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'place_order' },
    });
    check(res, { 'place_order status is 202': (r) => r.status === 202 });
  });

  sleep(0.2);
}
