---
name: kafka-lag-triage
description: >-
  Triage the order pipeline when orders are accepted but balances don't update:
  wallet-group consumer lag growing on crypto-orders, the wallet-service
  consumer stalled, crashed or scaled to 0, Postgres unreachable, or the Kafka
  broker (kafka-controller-0) down. Use for "orders are stuck", "balance didn't
  change", "consumer lag", "kafka_consumergroup_lag", or a lag panel climbing
  on the Performance & Load dashboard.
---

# Kafka consumer lag: triage runbook

## How the pipeline works

```
frontend --> order-service --produce--> Kafka topic crypto-orders (3 partitions)
                                            |
                         consumer group wallet-group
                                            v
                              wallet-service consumer --UPSERT--> postgres-service:5432
```

- Broker: Bitnami chart, KRaft, single combined node **`kafka-controller-0`**
  in namespace `kafka`. Clients use `kafka.kafka.svc.cluster.local:9092`.
- **The consumer and the wallet HTTP API share one process**
  (`services/wallet-service/index.js` + `consumer.js`). If the consumer is
  down, so is `GET /api/wallet/*`.
- `order-service` only produces. It returns `202` even when nothing consumes.
  Accepted orders with lag building means the consumer side is at fault.
- Delivery semantics (`consumer.js`, PLAT-506): a **transient** DB error is
  retried in place, forever, with capped backoff (max 10 s) and a heartbeat
  between attempts. The offset isn't committed, so **that partition blocks on
  purpose**. Malformed orders and Postgres data errors (SQLSTATE class
  22/23) are skipped with a log line and committed.
- Only 3 partitions. A wallet-service HPA replica beyond 3 sits idle and
  adds no throughput.

## Tools

- **Radar MCP** (read-only): `diagnose` on `deployment/wallet-service`,
  `get_workload_logs` with `grep`, `issues` in `kafka` and `crypto-wallet-app`.
- **Metrics**: Radar's Prometheus tools return nothing by default (the
  `ai-readonly` identity can't port-forward). Ask the operator to run
  `kubectl port-forward svc/monitoring-stack-kube-prom-prometheus 9090:9090 -n monitoring`
  and `make radar RADAR_FLAGS="--prometheus-url http://localhost:9090"`, or
  have them open the **"Crypto Wallet - Performance & Load"** Grafana dashboard.
  Stop any port-forward when done.

## Check order

### 1. Confirm and size the lag

```promql
sum by (topic, partition) (kafka_consumergroup_lag{consumergroup="wallet-group"})
sum by (topic) (rate(kafka_topic_partition_current_offset{topic="crypto-orders"}[5m]))   # produce rate
sum (rate(kafka_consumergroup_current_offset_sum{consumergroup="wallet-group"}[5m]))     # consume rate
```

- Lag on **one** partition, flat consume rate: a poison or blocked
  message on that partition. Go to step 3.
- Lag on **all** partitions: the consumer is gone or Postgres is down
  (steps 2–3).
- Lag rising and falling under load while the consume rate rises too:
  throughput, not a fault. Check CPU throttling and HPA status.
- No `kafka_*` series at all: kafka-exporter is down. That's a monitoring
  gap, not necessarily lag. Check the `kafka-exporter` pod (in `Init` =
  broker unreachable) and its ServiceMonitor (label `release: monitoring-stack`).

### 2. Is a consumer running?

```bash
kubectl get deploy,hpa wallet-service -n crypto-wallet-app
```

- **`replicas: 0`**: nothing will bring it back (PLAT-508). The HPA reports
  `ScalingActive=False (ScalingDisabled)` at 0, and ArgoCD ignores
  `spec.replicas` for HPA-managed Deployments. Recovery is a manual
  `kubectl scale deploy wallet-service --replicas=1 -n crypto-wallet-app`.
  **Ask before running it.**
- Pods not Ready or crash-looping: use the **pod-not-ready-triage** skill.

### 3. What is the consumer logging?

Grep the wallet-service logs for these markers (from `consumer.js`):

| Log line | Meaning |
|---|---|
| `⏳ Postgres unavailable (attempt N), retrying order at partition P offset O` | Blocked on the DB on purpose. Go to step 4 |
| `❌ Kafka consumer setup failed (attempt N)` | Can't connect or subscribe: broker down, or topic missing on a cold cluster. Go to step 5 |
| `⚠️ [Consumer] Crash (recovering)` | KafkaJS restarting the consumer. Frequent = broker flapping or rebalance storm |
| `⚠️ [Skipped] Malformed order` / `❌ [Skipped] Postgres rejected order` | Message dropped and committed. Not lag, but **data loss to report** (no DLQ yet, PLAT-511) |
| `✅ Applied ...` | Healthy, it's consuming |

### 4. Postgres

- Pod `postgres-db`, Service `postgres-service:5432`, PVC `postgres-data`
  (gp3, single AZ). Single instance, no failover, and **no readinessProbe**,
  so `Ready` doesn't mean it accepts connections.
- `GET /api/wallet/` returns `database: disconnected` when the pool can't connect.
- `ECONNREFUSED`: Postgres is restarting. `ETIMEDOUT` / connect timeout: check
  NetworkPolicy `allow-wallet-service-to-postgres` (only `app: wallet-service`
  may connect) and the Postgres pod/PVC events.
- `password authentication failed`: credentials drift between Vault and the
  running pods. Use the **vault-eso-secrets** skill.

### 5. Broker

```bash
kubectl get pods,pvc -n kafka
kubectl logs kafka-controller-0 -n kafka --tail=100
```

- Repeated broker restarts after ArgoCD renders: the KRaft ID regeneration
  issue (PLAT-518). The fix is `ignoreDifferences` + `RespectIgnoreDifferences`
  in `k8s/apps/kafka-app.yaml`. Check it's still in place.
- Optional, with the **operator's** credentials (exec isn't granted to Radar)
  and read-only:
  `kubectl exec -n kafka kafka-controller-0 -- kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group wallet-group`

## Forbidden without explicit approval

No offset resets (`--reset-offsets`), topic deletion, consumer-group deletion,
Postgres pod/PVC deletion, or producing test messages to `crypto-orders`. All
of these change shared state or lose data.

## Finish

Report which partitions lag and by how much, the blocking cause with the
log line or metric behind it, whether any orders were **skipped** (lost
rather than delayed), and the fix as a git change or an explicitly
approved live action.
