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
# Local: through the Ingress Controller (realistic L7 path — see root README)
make ingress-forward &                            # port-forwards ingress-nginx to localhost:8080
make test-load                                    # load-test.js, local k6 (or Docker if k6 isn't installed)
make test-load K6_SCRIPT=spike-test.js
make test-load K6_SCRIPT=kafka-pipeline-stress.js

# In-cluster: ephemeral k6 Pod, no port-forward, hits the frontend Service directly
make test-load K6_MODE=cluster K6_SCRIPT=spike-test.js
```

All three scripts send an explicit `Host: wallet.local` header (see
`helpers.js`) so that, when BASE_URL points at the ingress-nginx
port-forward, ingress-nginx routes the request to the `wallet` Ingress
instead of 404ing — there's no DNS on `localhost:8080` to convey which
virtual host is being requested. Override the target with `BASE_URL=...`,
or the header itself with `HOST_HEADER=...` (`HOST_HEADER=''` sends none),
e.g. when pointing at a direct `kubectl port-forward svc/frontend` instead,
where it's unnecessary but harmless.

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
