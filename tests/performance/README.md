# Performance & Load Testing (k6)

Three [k6](https://k6.io) scripts against `crypto-wallet-app`'s real API
surface — there's no login/auth service or order-status endpoint in this
app today, so "user journey" maps to what actually exists:

| Script | Simulates | Pattern |
|---|---|---|
| `load-test.js` | Realistic journey: get balance -> place order -> poll balance until processed | Ramp 5 -> 100 VUs over 3 min, soak, ramp down |
| `spike-test.js` | Sudden traffic burst | 0 -> 300 VUs in 15s, hold, drop |
| `kafka-pipeline-stress.js` | Rapid-fire `/orders` to stress the Kafka producer/consumer pipeline | Fixed 50 orders/sec (constant-arrival-rate) for 2 min, independent of VU count |

Thresholds on the synchronous HTTP endpoints:

| Script | `http_req_duration` | `http_req_failed` |
|---|---|---|
| `load-test.js`, `kafka-pipeline-stress.js` | p95 < 200ms (steady-state SLO) | rate < 1% |
| `spike-test.js` | p95 < 800ms (degradation ceiling) | rate < 1% |

`load-test.js` and `kafka-pipeline-stress.js` also track `order_processing_lag`
(ms from order submission to the balance reflecting it) as a separate,
informational Trend metric — that's Kafka's async processing time, not an
HTTP SLO, so it's not conflated with the two thresholds above.

**Why the spike test's latency limit is looser:** going from 0 to 300 VUs
in 15s outruns HPA scale-out on this cluster, because new replicas take
about 30–60s to become Ready. Holding the 200ms steady-state p95 through
that is unrealistic. The spike test checks resilience instead: zero errors,
no restarts, and latency that degrades but stays under 800ms.

## Running

### In-cluster (use this for baseline numbers)

`K6_MODE=cluster` runs each script as an ephemeral `grafana/k6` Pod in
`crypto-wallet-app`. The Pod hits the `frontend` Service directly, so no
local port-forward sits in the latency path, and it pushes metrics to
Prometheus via remote write. The Pod carries the label
`app: k6-load-generator`, which the namespace's default-deny NetworkPolicy
needs in order to let it reach the frontend
(`k8s/components/network-policies.yaml`). `run-in-cluster.sh` deletes the Pod and its
`k6-scripts` ConfigMap when the run ends.

1. **Prerequisites:** `kubectl` points at the EKS cluster
   (`kubectl config current-context`). The app is healthy and the HPAs are
   at their resting replica count, so runs start from the same state:
   ```bash
   kubectl get pods,hpa -n crypto-wallet-app
   ```
2. **Optional: watch it live.** In a second terminal, port-forward Grafana
   (see [Observing it live in Grafana](#observing-it-live-in-grafana)) and
   open the **Crypto Wallet - Performance & Load** dashboard. In another,
   `kubectl get hpa,pods -n crypto-wallet-app -w`.
3. **Run the suite one script at a time** from the repo root:
   ```bash
   make test-load K6_MODE=cluster                                    # load-test.js            (~6 min)
   make test-load K6_MODE=cluster K6_SCRIPT=spike-test.js            # spike-test.js           (~1.5 min)
   make test-load K6_MODE=cluster K6_SCRIPT=kafka-pipeline-stress.js # kafka-pipeline-stress.js (~2 min)
   ```
   Between runs, wait for the HPAs to scale back to 1 replica each (about
   5 min after the spike test, set by the default scale-down stabilization
   window). Starting the next run with the cluster already scaled out
   skews the baseline.
4. **Read the result.** The k6 end-of-run summary is the source of truth:
   every threshold prints `✓`/`✗`, and `make` exits non-zero (k6 exit code
   99) if any threshold is breached. The first output line names the run's
   `testid` (`k6-<script>-<epoch>`). Pick that `testid` in the Grafana
   dashboard's test id picker.
5. **Confirm cleanup:** `kubectl get pods,cm -n crypto-wallet-app | grep k6`
   should print nothing.

Compare the results with the [baselines](#baselines-in-cluster-eks) below.
A regression is a p95 or error rate meaningfully above the baseline, even
if it's still under the SLO.

### Local (through the Ingress Controller)

```bash
make ingress-forward &                            # port-forwards ingress-nginx to localhost:8080
make test-load                                    # load-test.js, local k6 (or Docker if k6 isn't installed)
make test-load K6_SCRIPT=spike-test.js
make test-load K6_SCRIPT=kafka-pipeline-stress.js
```

Local runs go through the port-forward, which adds latency of its own.
They're useful for checking that a script works, not for numbers to compare
against the baselines.

All three scripts send an explicit `Host: wallet.local` header (see
`helpers.js`) so that, when BASE_URL points at the ingress-nginx
port-forward, ingress-nginx routes the request to the `wallet` Ingress
instead of 404ing — there's no DNS on `localhost:8080` to convey which
virtual host is being requested. Override the target with `BASE_URL=...`,
or the header itself with `HOST_HEADER=...` (`HOST_HEADER=''` sends none),
e.g. when pointing at a direct `kubectl port-forward svc/frontend` instead,
where it's unnecessary but harmless.

`kafka-pipeline-stress.js`'s rate is tunable: `k6 run -e ORDERS_PER_SEC=100 kafka-pipeline-stress.js`.

## Baselines (in-cluster, EKS)

Recorded 2026-10-11 with `make test-load K6_MODE=cluster`, run one after
another, with the HPAs back at 1 replica before each run. Application
manifests as of `main` @ `843a03a`. The spike test was re-run after its
threshold changed to p95 < 800ms.

**Environment:** EKS 1.31 on 3× `t3.medium` nodes. `frontend`,
`order-service` and `wallet-service` each start at 1 replica (HPA min 1,
max 3, CPU target 70%). Kafka consumer group `wallet-group`. The k6 Pod is
limited to 1 CPU and 512Mi.

### Summary

| | `load-test.js` | `spike-test.js` | `kafka-pipeline-stress.js` |
|---|---|---|---|
| **Result** | ✅ PASS | ✅ PASS | ✅ PASS |
| Duration | 5m40s | 1m30s | 2m |
| VUs (peak) | 100 | 300 | 55 (of 100 allocated) |
| HTTP requests | 16,653 | 77,018 | 12,000 |
| Throughput | 48.6 req/s | 854.2 req/s | 99.2 req/s (49.6 orders/s, 0 dropped) |
| Iterations | 5,551 (16.2/s) | 38,509 (427.1/s) | 6,000 (49.6/s) |
| `http_req_duration` avg / med | 4.75ms / 4.05ms | 191.6ms / 120.08ms | 5.27ms / 4.35ms |
| `http_req_duration` p90 | 6.63ms | 556.39ms | 7.26ms |
| `http_req_duration` **p95** | **8.88ms** ✓ (< 200ms) | **619.06ms** ✓ (< 800ms) | **10.03ms** ✓ (< 200ms) |
| `http_req_duration` max | 92ms | 806.03ms | 258.46ms |
| `http_req_failed` (SLO < 1%) | **0.00%** ✓ (0 / 16,653) | **0.00%** ✓ (0 / 77,018) | **0.00%** ✓ (0 / 12,000) |
| Checks passed | 100% | 100% | 100% |
| `order_processing_lag` p90 / p95 (limit p95 < 5s) | 1.94s / **1.97s** ✓ | not measured | 1.01s / **1.02s** ✓ |
| Kafka `wallet-group` consumer lag (peak) | ≤ 1 msg | 15,109 msgs, drained to 0 within ~50s of the spike ending | ≤ 1 msg |
| HPA scaling (replicas, start → peak) | `wallet-service` 1 → 2, others stayed at 1 | all three 1 → 3 (max) within ~50s (`frontend` first, ~30s in) | `wallet-service` 1 → 3, `frontend` and `order-service` 1 → 2 |
| Pod restarts / Pending pods | 0 / 0 | 0 / 0 | 0 / 0 |
| Prometheus `testid` | `k6-load-test-1791714712` | `k6-spike-test-1791716871` | `k6-kafka-pipeline-stress-1791715566` |

### Notes on reading these numbers

- **`spike-test.js` passes with about 23% headroom (p95 619ms against 800ms).**
  Latency climbs while 1 replica of each service takes the burst, before the
  HPA scale-out lands. Nothing errored and nothing restarted: the system got
  slower but didn't fail. Kafka lag built up to about 15k messages while the
  consumer fell behind, then cleared once the spike ended. An earlier run on
  the same day measured p95 672ms and 8.4k peak lag, so expect about ±10% on
  p95 between runs. A p95 heading toward 800ms, any errors, any restarts, or
  lag that doesn't drain is a regression.
- **`order_processing_lag` has a floor set by the poll interval.** The
  scripts poll the balance once per second (`kafka-pipeline-stress.js`) or
  after a 0.5–1.5s think time (`load-test.js`), so the measured lag can't be
  much below 1s even when the consumer is faster. The real pipeline latency
  is lower than these figures. Kafka consumer-group lag in Grafana is the
  closer measure.
- **`kafka-pipeline-stress.js` sends 2 HTTP requests per iteration**: the
  `POST /orders` plus at least one balance poll. That's why its request rate
  is about double the 50 orders/s arrival rate.
- **Cluster capacity:** the spike pushed the cluster to 53 pods, close to
  the 17-pods-per-node VPC-CNI ceiling on these `t3.medium` nodes. Raising
  any HPA's `maxReplicas` could leave pods `Pending` with "Too many pods"
  during a spike.

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

Then open **Dashboards -> Crypto Wallet - Performance & Load**
(`/d/crypto-wallet-performance`). It's provisioned from git
(`k8s/apps/monitoring/dashboards/crypto-wallet-performance.json`, synced by
the `monitoring-custom` ArgoCD Application and loaded by Grafana's dashboard
sidecar), and puts everything a load test moves on one screen:

| Row | Panels | Source |
|---|---|---|
| k6 load test | Active VUs, request rate, `http_req_duration` p95/p99/avg per endpoint (200ms SLO line), `http_req_failed` rate (1% SLO line), `order_processing_lag` | k6 -> Prometheus remote write |
| Autoscaling & pods | `wallet-service` available pods, HPA current/desired/max replicas, HPA CPU utilization vs 70% target, ready pods per Deployment | kube-state-metrics |
| Kafka | `kafka_consumergroup_lag` (total + per topic), produce vs consume rate | kafka-exporter (`k8s/apps/kafka/`) |
| Resource utilization | CPU per pod, CPU % of request (what the HPA scales on), memory working set, memory % of limit, CPU throttling | cAdvisor + kube-state-metrics |

Variables at the top pick the namespace (default `crypto-wallet-app`), the
Kafka consumer group (default `wallet-group`) and the **k6 test id**.

### Getting k6 metrics into Prometheus

k6 runs are short-lived and expose nothing for Prometheus to scrape, so
they push instead: Prometheus has its remote-write receiver enabled
(`enableRemoteWriteReceiver` in `k8s/apps/monitoring-app.yaml`) and k6's
`experimental-prometheus-rw` output writes to it.

- **`K6_MODE=cluster`** does this automatically — `run-in-cluster.sh`
  pushes to `monitoring-stack-kube-prom-prometheus.monitoring.svc` and tags
  the run `testid=<pod name>`, which then shows up in the dashboard's test
  id picker. `K6_PROMETHEUS_RW_SERVER_URL='' make test-load K6_MODE=cluster`
  turns it off.
- **Local runs** don't push by default (the CI Kind job has no Prometheus
  to push to). To push one by hand:
  ```bash
  kubectl port-forward svc/monitoring-stack-kube-prom-prometheus 9090:9090 -n monitoring &
  K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
  K6_PROMETHEUS_RW_TREND_STATS='p(95),p(99),avg,max' \
  BASE_URL=http://localhost:8080 \
    k6 run -o experimental-prometheus-rw --tag testid=local-$(date +%s) tests/performance/load-test.js
  ```

`K6_PROMETHEUS_RW_TREND_STATS` matters: Trend metrics are only sent as the
stats listed there, as `k6_<metric>_p95` / `_p99` / `_avg` / `_max` (in
seconds), which is what the dashboard queries. It defaults to `p(99)`
only, so without it the p95/avg panels stay empty.

k6's own end-of-run summary remains the pass/fail source of truth for the
thresholds; the dashboard is for seeing *why* — which endpoint degraded,
whether the HPA had scaled out yet, whether Kafka lag was building, which
pod hit its CPU limit. Watch restarts directly with:

```bash
kubectl get pods -n crypto-wallet-app -w
```
