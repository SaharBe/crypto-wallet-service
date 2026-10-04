// Stresses the order-service -> Kafka -> wallet-service consumer pipeline
// specifically: hammers POST /orders at a fixed arrival rate (independent
// of how many VUs that takes) and measures end-to-end processing delay —
// there is no kafka-exporter/JMX metrics wired into Prometheus in this
// cluster yet (see k8s/apps/kafka-app.yaml — metrics are disabled on the
// bitnami chart), so consumer lag isn't visible as a Prometheus/Grafana
// metric today. This script measures the same thing from the application's
// point of view instead: for each order, how long until wallet-service's
// consumer has applied it and GET /balance/:userId reflects it.
//
// Run (default BASE_URL is the ingress-nginx port-forward, already set):
//   k6 run kafka-pipeline-stress.js
// Tune rate: k6 run -e ORDERS_PER_SEC=100 kafka-pipeline-stress.js
// All requests send Host: wallet.local so ingress-nginx routes them to the
// wallet Ingress — see helpers.js. Override with BASE_URL / HOST_HEADER.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { BASE_URL, randomUserId, randomCoin, randomAmount, randomAction, withHost } from './helpers.js';

const ordersPerSecond = parseInt(__ENV.ORDERS_PER_SEC || '50', 10);

const orderProcessingLag = new Trend('order_processing_lag', true);
const ordersFailed = new Counter('orders_failed');
const lagPollTimeouts = new Counter('lag_poll_timeouts');

const MAX_POLL_ATTEMPTS = 10;
const POLL_INTERVAL_S = 1;

export const options = {
  scenarios: {
    orders_firehose: {
      executor: 'constant-arrival-rate',
      rate: ordersPerSecond,
      timeUnit: '1s',
      duration: '2m',
      preAllocatedVUs: Math.max(ordersPerSecond * 2, 20),
      maxVUs: Math.max(ordersPerSecond * 4, 50),
    },
  },
  thresholds: {
    // Required SLOs for the /orders request itself.
    http_req_duration: ['p(95)<200'],
    http_req_failed: ['rate<0.01'],
    // Informational: end-to-end Kafka pipeline delay, not an HTTP SLO.
    order_processing_lag: ['p(95)<5000'],
  },
};

export default function () {
  const userId = randomUserId('kstress');
  const coin = randomCoin();
  const payload = JSON.stringify({
    userId,
    coin,
    amount: randomAmount(),
    action: randomAction(),
  });

  const submittedAt = Date.now();
  const res = http.post(`${BASE_URL}/api/order/orders`, payload, {
    headers: withHost({ 'Content-Type': 'application/json' }),
    tags: { name: 'submit_order' },
  });

  const accepted = check(res, { 'submit_order status is 202': (r) => r.status === 202 });
  if (!accepted) {
    ordersFailed.add(1);
    return;
  }

  let processed = false;
  for (let attempt = 0; attempt < MAX_POLL_ATTEMPTS && !processed; attempt++) {
    sleep(POLL_INTERVAL_S);
    const pollRes = http.get(`${BASE_URL}/api/wallet/balance/${userId}`, {
      headers: withHost(),
      tags: { name: 'poll_balance_for_lag' },
    });
    if (pollRes.status === 200) {
      const balances = pollRes.json('balances') || [];
      processed = balances.some((b) => b.coin === coin);
    }
  }

  if (processed) {
    orderProcessingLag.add(Date.now() - submittedAt);
  } else {
    lagPollTimeouts.add(1);
  }
}
