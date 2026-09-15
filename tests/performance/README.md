# Performance & Load Testing (k6)

Three [k6](https://k6.io) scripts against `crypto-wallet-app`'s real API
surface — there's no login/auth service or order-status endpoint in this
app today, so "user journey" maps to what actually exists:

| Script | Simulates | Pattern |
|---|---|---|
| `load-test.js` | Realistic journey: get balance -> place order -> poll balance until processed | Ramp 5 -> 100 VUs over 3 min, soak, ramp down |
| `spike-test.js` | Sudden traffic burst | 0 -> 300 VUs in 15s, hold, drop |
| `kafka-pipeline-stress.js` | Rapid-fire `/orders` to stress the Kafka producer/consumer pipeline | Fixed 50 orders/sec (constant-arrival-rate) for 2 min, independent of VU count |

All three enforce the required SLOs on the synchronous HTTP endpoints:

- `http_req_duration`: p95 < 200ms
- `http_req_failed`: rate < 1%

`load-test.js` and `kafka-pipeline-stress.js` also track `order_processing_lag`
(ms from order submission to the balance reflecting it) as a separate,
informational Trend metric — that's Kafka's async processing time, not an
HTTP SLO, so it's not conflated with the two thresholds above.

**Note:** `spike-test.js` is *expected* to breach these thresholds — finding
where the SLOs break under a sudden burst is the point of that test, not a
bug in the script.

## Running

```bash
# Local: needs a port-forward first
kubectl port-forward svc/frontend 8080:80 -n crypto-wallet-app &
make test-load                                    # load-test.js, local k6 (or Docker if k6 isn't installed)
make test-load K6_SCRIPT=spike-test.js
make test-load K6_SCRIPT=kafka-pipeline-stress.js

# In-cluster: ephemeral k6 Pod, no port-forward, hits the frontend Service directly
make test-load K6_MODE=cluster K6_SCRIPT=spike-test.js
```

`kafka-pipeline-stress.js`'s rate is tunable: `k6 run -e ORDERS_PER_SEC=100 kafka-pipeline-stress.js`.

## Observing it live in Grafana

Grafana is `monitoring-stack-grafana` in the `monitoring` namespace
(kube-prometheus-stack). Port-forward it in a separate terminal before — or
during — a test run:

```bash
kubectl port-forward svc/monitoring-stack-grafana 3000:80 -n monitoring
# open http://localhost:3000 — admin credentials are in the
# grafana-admin-credentials Secret (monitoring namespace), synced from
# Vault by External Secrets.
```

What to look at, and where to find it (all via the built-in
**Kubernetes / Compute Resources / Namespace (Pods)** dashboard, or build
ad-hoc panels from these PromQL queries in Explore):

- **CPU / Memory scaling** — per-pod usage vs. the 100m/128Mi requests and
  200m/256Mi limits set on `order-service` and `wallet-service`
  (`k8s/components/order-service.yaml`, `wallet-service.yaml`):
  ```promql
  sum(rate(container_cpu_usage_seconds_total{namespace="crypto-wallet-app"}[1m])) by (pod)
  sum(container_memory_working_set_bytes{namespace="crypto-wallet-app"}[1m]) by (pod)
  ```
  There's no HorizontalPodAutoscaler configured on these Deployments yet —
  `order-service` is fixed at 2 replicas, `wallet-service` at 1 — so under
  load you'll see pods hit their CPU/memory limits (and get OOMKilled or
  throttled) rather than the ReplicaSet scaling out. That's useful signal
  in its own right: it tells you where an HPA would need to kick in.
  Watch restarts directly:
  ```bash
  kubectl get pods -n crypto-wallet-app -w
  ```

- **HTTP latency** — kube-prometheus-stack scrapes node/cAdvisor and
  kube-state-metrics by default, but neither `order-service` nor
  `wallet-service` currently exposes a `/metrics` endpoint, so
  request-duration percentiles aren't in Prometheus. Treat k6's own
  `http_req_duration` output (printed at the end of the run, or streamed
  with `k6 run --out ...`) as the source of truth for the p95 SLO.

- **Kafka lag** — the Kafka chart (`k8s/apps/kafka-app.yaml`) has its
  metrics exporter disabled, so there's no `kafka_consumergroup_lag`
  series in Prometheus either. `load-test.js` and
  `kafka-pipeline-stress.js` measure the same thing from the application
  side instead — `order_processing_lag`, printed in the k6 summary — by
  timing how long after a `POST /orders` the balance the consumer writes
  actually shows up. If you want the real Kafka-side metric later, that
  means turning on `metrics.kafka.enabled` (and a
  ServiceMonitor) in `k8s/apps/kafka-app.yaml`.
