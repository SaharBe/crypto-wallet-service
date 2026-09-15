// Realistic user journey against the crypto-wallet-app frontend
// (nginx -> wallet-service / order-service), ramping 5 -> 100 VUs over 3
// minutes, holding at peak, then ramping down.
//
// There is no login/auth service in this app yet, and no dedicated
// order-status endpoint — orders are processed asynchronously off a Kafka
// topic (see services/order-service/index.js and
// services/wallet-service/consumer.js). The journey below reflects the
// real API surface:
//   1. GET  /api/wallet/balance/:userId   — "log in" / open the wallet view
//   2. POST /api/order/orders             — place an order (202 = queued)
//   3. GET  /api/wallet/balance/:userId   — poll until the consumer has
//                                           applied it, standing in for
//                                           "poll order status"
//
// Run: BASE_URL=http://localhost:8080 k6 run load-test.js
// (see ../../Makefile's `test-load` target, or run-in-cluster.sh)
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Trend } from 'k6/metrics';
import { BASE_URL, randomUserId, randomCoin, randomAmount, randomAction, randomSleep } from './helpers.js';

const orderProcessingLag = new Trend('order_processing_lag', true);

export const options = {
  scenarios: {
    user_journey: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 5 },   // warm up
        { duration: '3m', target: 100 },  // ramp 5 -> 100 VUs over 3 minutes
        { duration: '2m', target: 100 },  // soak at peak
        { duration: '30s', target: 0 },   // cool down
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    // Required SLOs — apply to the synchronous HTTP endpoints.
    http_req_duration: ['p(95)<200'],
    http_req_failed: ['rate<0.01'],
    // Informational only: async Kafka processing time has no bearing on
    // the two SLOs above, tracked separately so it doesn't get conflated.
    order_processing_lag: ['p(95)<5000'],
  },
};

export default function () {
  const userId = randomUserId('load');

  group('get_balance', () => {
    const res = http.get(`${BASE_URL}/api/wallet/balance/${userId}`, {
      tags: { name: 'get_balance' },
    });
    check(res, { 'get_balance status is 200': (r) => r.status === 200 });
  });

  sleep(randomSleep(0.5, 1.5));

  const coin = randomCoin();
  const submittedAt = Date.now();

  let orderAccepted = false;
  group('place_order', () => {
    const payload = JSON.stringify({
      userId,
      coin,
      amount: randomAmount(),
      action: randomAction(),
    });
    const res = http.post(`${BASE_URL}/api/order/orders`, payload, {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'place_order' },
    });
    orderAccepted = check(res, { 'place_order status is 202': (r) => r.status === 202 });
  });

  if (!orderAccepted) {
    sleep(randomSleep(1, 2));
    return;
  }

  sleep(randomSleep(0.3, 1));

  group('poll_order_status', () => {
    const maxAttempts = 5;
    let processed = false;
    for (let attempt = 0; attempt < maxAttempts && !processed; attempt++) {
      sleep(1);
      const res = http.get(`${BASE_URL}/api/wallet/balance/${userId}`, {
        tags: { name: 'poll_order_status' },
      });
      check(res, { 'poll_order_status status is 200': (r) => r.status === 200 });
      if (res.status === 200) {
        const balances = res.json('balances') || [];
        processed = balances.some((b) => b.coin === coin);
      }
    }
    if (processed) {
      orderProcessingLag.add(Date.now() - submittedAt);
    }
  });

  sleep(randomSleep(1, 2));
}
