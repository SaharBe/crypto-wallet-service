# Crypto Wallet Service: a GitOps Internal Developer Platform

[![PR Checks](https://github.com/SaharBe/crypto-wallet-service/actions/workflows/pr-checks.yml/badge.svg)](https://github.com/SaharBe/crypto-wallet-service/actions/workflows/pr-checks.yml)
[![CI/CD](https://github.com/SaharBe/crypto-wallet-service/actions/workflows/ci.yml/badge.svg)](https://github.com/SaharBe/crypto-wallet-service/actions/workflows/ci.yml)

This is a platform-engineering portfolio project. It is a small event-driven
crypto wallet (Node.js microservices, Kafka, PostgreSQL) running on an
**internal developer platform**. The platform is built the way a real
platform team would build one:

- **Git is the only way to change the cluster.** ArgoCD reconciles every
  component from this repository (App-of-Apps plus an ApplicationSet), with
  `selfHeal` and `prune` turned on.
- **Secrets never touch git.** HashiCorp Vault holds them, and External
  Secrets Operator syncs them into the cluster. Vault itself is configured
  by Terraform.
- **Policy-as-code at admission.** Kyverno rejects any workload Pod that
  lacks CPU and memory limits.
- **Observable and load-tested.** Prometheus and Grafana come with
  dashboards stored as code. k6 load tests push their metrics into
  Prometheus, and every PR runs a k6 performance gate on an ephemeral Kind
  cluster.
- **Fully automated delivery.** A merge to `main` builds images, pushes
  them to ECR, and pins the new immutable tag in the manifests through an
  auto-merged PR. ArgoCD then rolls the change out. Nobody runs
  `kubectl apply` by hand.

The wallet app is deliberately simple. The point of the project is
everything around it.

> **Deeper reading:** [architecture.md](architecture.md) (component
> breakdown, sync waves, secret flow, CI/CD pipeline) ·
> [CONTRIBUTING.md](CONTRIBUTING.md) (branching, PRs, live-cluster
> validation) · [tests/performance/README.md](tests/performance/README.md)
> (k6 suite)

## Table of Contents

- [Architecture at a Glance](#architecture-at-a-glance)
- [Tech Stack](#tech-stack)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quickstart A: Local Development (Docker Compose)](#quickstart-a-local-development-docker-compose)
- [Quickstart B: Cloud Deployment (Terraform + EKS + ArgoCD)](#quickstart-b-cloud-deployment-terraform--eks--argocd)
- [Local vs. Production Traffic Routing](#local-vs-production-traffic-routing)
- [Operations & Makefile Commands](#operations--makefile-commands)
- [CI/CD](#cicd)
- [Autoscaling & Resilience Strategy](#autoscaling--resilience-strategy)
- [Security Model](#security-model)
- [Development & Contributing Workflow](#development--contributing-workflow)

## Architecture at a Glance

**Services** live in `services/`. Each one is a Deployment plus a Service in
`k8s/components/`, namespace `crypto-wallet-app`:

- **frontend** (nginx): serves a static SPA and proxies `/api/wallet/*` and
  `/api/order/*` to the backend Services on the same origin, so no CORS is
  needed.
- **order-service** (Express + KafkaJS): accepts `POST /orders`, publishes
  the order to the `crypto-orders` Kafka topic, and returns
  `202 Accepted` right away. Orders are processed asynchronously.
- **wallet-service** (Express + KafkaJS + `pg`): consumes `crypto-orders`,
  applies the balance change in PostgreSQL, and serves
  `GET /balance/:userId`.
- **postgres-db**: the wallet ledger, stored on a `gp3` EBS volume.
- **Kafka** (Bitnami chart, KRaft mode): decouples order intake from
  wallet-balance updates.

```mermaid
flowchart LR
    Client["k6 / browser"] -->|"Host: wallet.local"| Ing["ingress-nginx<br/>Ingress: wallet"]
    Ing --> FE["frontend<br/>(nginx + SPA)"]
    FE -->|"/api/order/*"| OS["order-service"]
    FE -->|"/api/wallet/*"| WS["wallet-service"]
    OS -->|"produce"| K["Kafka<br/>topic: crypto-orders"]
    K -->|"consume"| WS
    WS --> PG["PostgreSQL"]

    HPA["HPA x3<br/>(frontend / order-service / wallet-service)"]:::ctl -.->|"CPU util -> scale"| OS
    HPA -.-> WS
    HPA -.-> FE
    Kyverno["Kyverno<br/>ClusterPolicy"]:::ctl -.->|"admission: require CPU/mem limits"| FE
    ArgoCD["ArgoCD<br/>App-of-Apps"]:::ctl -.->|"GitOps sync"| FE

    classDef ctl fill:#e0e7ff,stroke:#4338ca,color:#1e1b4b
```

**Control plane:** a single `root-application` (App-of-Apps,
`k8s/root-app.yaml`) points ArgoCD at `k8s/apps/`. That directory fans out
into one `Application` or `ApplicationSet` per concern: ingress-nginx,
Kyverno and its policies, Vault, External Secrets, Kafka, metrics-server,
the monitoring stack, and the wallet app itself. Sync waves order the
bootstrap so that CRDs and secret stores exist before anything consumes
them. [architecture.md](architecture.md) covers the full breakdown.

## Tech Stack

| Area | Technology | Role in the platform |
|---|---|---|
| Cloud & IaC | **AWS EKS 1.31**, VPC, ECR, EBS CSI · **Terraform** | 3× `t3.medium` managed node group in private subnets. Remote state in S3 with a DynamoDB lock table (`terraform/state-backend`) |
| Orchestration | **Kubernetes**, **Kustomize** | Base manifests in `k8s/components`, plus a CI overlay for Kind |
| GitOps | **ArgoCD** (App-of-Apps + ApplicationSet) | Continuous reconciliation from `main` with `selfHeal` + `prune` |
| Secrets | **HashiCorp Vault** + **External Secrets Operator** | Vault KV v2 with Kubernetes auth and one scoped role per consumer, configured by Terraform (`terraform/vault-config`) |
| Policy | **Kyverno** | `require-resource-limits` ClusterPolicy in **Enforce** mode |
| Ingress | **ingress-nginx** | Host-based L7 routing for `wallet`, `argocd`, `grafana` and `vault` `.local` |
| Autoscaling | **HPA** + **metrics-server** | CPU-based scaling for all three services |
| Messaging | **Apache Kafka** (Bitnami chart, KRaft) + **kafka-exporter** | Async order pipeline, with consumer-lag metrics |
| Database | **PostgreSQL** | Wallet ledger; credentials delivered from Vault |
| Services | **Node.js** (Express, KafkaJS, `pg`), **nginx** | `order-service`, `wallet-service`, `frontend` |
| Observability | **Prometheus** + **Grafana** (kube-prometheus-stack) | Dashboards stored as JSON in git. The remote-write receiver ingests k6 metrics |
| Performance | **k6** | Load, spike and Kafka-pipeline stress scripts, run locally or as an ephemeral in-cluster Pod |
| CI/CD | **GitHub Actions** | PR gate (lint, kustomize, kubeconform, helm template, k6 on Kind) and build → ECR → auto-pin pipeline |
| Local dev | **Docker Compose** | The full app stack with no cloud dependencies |

## Repository Layout

```
.
├── services/                 # order-service, wallet-service (Node.js), frontend (nginx)
├── k8s/
│   ├── root-app.yaml         # App-of-Apps entry point (applied once by bootstrap.sh)
│   ├── apps/                 # One ArgoCD Application per platform concern (+ ApplicationSet)
│   ├── components/           # Wallet app base manifests (Deployments, HPA, ExternalSecret, Postgres)
│   ├── overlays/ci/          # Kind overlay used by the PR performance gate
│   └── bootstrap-secrets/    # Template for the one imperatively-seeded repo credential
├── terraform/
│   ├── state-backend/        # S3 + DynamoDB remote state (run first)
│   ├── infra/                # VPC, EKS, ECR, EBS CSI driver
│   ├── vault-config/         # Vault auth, policies, roles, KV secrets
│   └── modules/vault-config/ # Reusable "one consumer = one role + policy + secret" module
├── tests/performance/        # k6 scripts + in-cluster runner
├── local-dev/                # Compose init SQL + end-to-end smoke test
├── scripts/                  # setup-hosts, CI helpers
├── docker-compose.yml        # Local stack
├── bootstrap.sh              # End-to-end cloud bootstrap (`make up`)
└── Makefile                  # Single operations entry point (`make help`)
```

## Prerequisites

| Tool | Local path (A) | Cloud path (B) | Used for |
|---|:---:|:---:|---|
| [Docker](https://docs.docker.com/get-docker/) with Compose v2 | ✅ | ✅ | Running the local stack and building images (`make build`) |
| `make`, `bash`, `curl` | ✅ | ✅ | Every workflow runs through the root `Makefile` |
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | | ✅ | Talking to the EKS cluster |
| [AWS CLI](https://aws.amazon.com/cli/) (configured) | | ✅ | EKS auth and ECR login |
| [`terraform`](https://developer.hashicorp.com/terraform/install) | | ✅ | Provisioning AWS infrastructure and configuring Vault |
| [`argocd` CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) | | ✅ | Admin login and verification at bootstrap |
| `envsubst` (`gettext` package) | | ✅ | Templating `k8s/root-app.yaml` at bootstrap |
| [`k6`](https://k6.io/docs/get-started/installation/) | optional | optional | Load testing. Without it, `make test-load` falls back to the `grafana/k6` Docker image |
| [`helm`](https://helm.sh/docs/intro/install/) | | optional | Only for running the Helm-values PR check locally. ArgoCD renders the charts itself |

The cloud path provisions **billable AWS resources** (EKS control plane,
3 EC2 nodes, NAT gateway, EBS volumes). Run `make down` when you are done.

## Quickstart A: Local Development (Docker Compose)

This path runs the whole application on your machine: Postgres, ZooKeeper
and Kafka, `wallet-service`, `order-service` and `frontend`. It uses the
same ports, environment variables and Kafka topic as the EKS deployment.
It needs no AWS account, Vault or Kubernetes, only Docker with Compose v2.

```bash
make local-up      # first run creates .env with a random local DB password, then builds, starts and waits for healthchecks
make local-smoke   # end-to-end verification (see below)
open http://localhost:8088   # or xdg-open on Linux
make local-down    # stop and keep the data
make local-clean   # stop AND delete the volumes (Postgres/Kafka data; init SQL runs again next time)
```

**Ports.** All are bound to `127.0.0.1` only and can be changed in `.env`.

| Service | Host URL | In-network address | Key env |
|---|---|---|---|
| `frontend` | `http://localhost:8088` | `frontend:8080` | `WALLET_SERVICE_HOST=wallet-service`, `ORDER_SERVICE_HOST=order-service`, `BACKEND_PORT=3000` |
| `wallet-service` | `http://localhost:3001` | `wallet-service:3000` | `KAFKA_BROKERS=kafka:9092`, `DB_HOST=postgres`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` |
| `order-service` | `http://localhost:3002` | `order-service:3000` | `KAFKA_BROKERS=kafka:9092` |
| `postgres` | `localhost:5432` | `postgres:5432` | `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` from `.env` |
| `kafka` | `localhost:29092` (EXTERNAL listener) | `kafka:9092` (INTERNAL listener) | PLAINTEXT, single broker |

Port 8080 is avoided on purpose, because `make ingress-forward` uses it
for the cloud path. `.env` is gitignored and generated from
[`.env.example`](.env.example).

**Startup order** is enforced with `depends_on` health conditions:
`postgres` (pg_isready) and `zookeeper` → `kafka` (broker answers) →
`kafka-init` (one-shot job that creates `crypto-orders` with 3 partitions,
RF 1) → `wallet-service` + `order-service` (`/health`) → `frontend`
(`/healthz`). Everything shares one bridge network, `wallet-net`.

**What `make local-smoke` verifies** ([`local-dev/smoke-test.sh`](local-dev/smoke-test.sh)).
Every check goes through the frontend's nginx proxy, the same path the
browser uses:

1. `local-dev/postgres-init/01-init-schema.sql` still matches
   `k8s/components/postgres-init-configmap.yaml`, so local and cluster
   schemas cannot drift.
2. `/healthz`, `/api/wallet/health` and `/api/order/health` respond, and
   wallet-service reports Postgres as `connected`.
3. `POST /api/order/orders` (buy 1.5 BTC for a unique `userId`) returns
   `202`, meaning order-service published the order to Kafka.
4. Within 60s, `GET /api/wallet/balance/<userId>` shows the new balance.
   This proves that wallet-service consumed the event and wrote it to
   Postgres.

**Manual checks:**

```bash
make local-logs SVC=wallet-service      # watch the consumer process orders
docker compose exec kafka kafka-consumer-groups --bootstrap-server kafka:9092 --describe --group wallet-group
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select * from wallets"'
```

**Differences from production.** Local Kafka runs in ZooKeeper mode on
Confluent images, while production uses Bitnami in KRaft mode. The
client-facing contract is identical: PLAINTEXT on `:9092`, topic
`crypto-orders`, consumer group `wallet-group`. Local credentials come
from `.env` rather than from Vault → ESO. There is no Ingress, HPA,
Kyverno or Prometheus/Grafana locally.

## Quickstart B: Cloud Deployment (Terraform + EKS + ArgoCD)

1. **Create the remote-state backend.** This is a one-time step per AWS
   account:
   ```bash
   terraform -chdir=terraform/state-backend init
   terraform -chdir=terraform/state-backend apply
   terraform -chdir=terraform/state-backend output   # bucket + lock table names
   ```
   Copy `terraform/infra/backend.hcl.example` and
   `terraform/vault-config/backend.hcl.example` to `backend.hcl` in the
   same directories, then fill them in from those outputs. Both copies are
   gitignored.

2. **Configure bootstrap secrets.** They are read from a gitignored file
   and never committed:
   ```bash
   cp secrets.env.example secrets.env
   # fill in REPO_URL, VAULT_TOKEN, DB_USERNAME/PASSWORD, GITHUB_USERNAME/PAT,
   # ARGOCD_ADMIN_PASSWORD, ECR_REGISTRY
   ```

3. **Bring the platform up:**
   ```bash
   make up          # runs ./bootstrap.sh end to end
   ```
   `bootstrap.sh` takes these steps:
   1. Provisions VPC, EKS, ECR and the EBS CSI driver with Terraform.
   2. Builds the first service images and pushes them to ECR.
   3. Installs ArgoCD and sets the admin password.
   4. Seeds the one bootstrap repo credential and applies the App-of-Apps.
   5. Runs `make vault-init` as soon as Vault is healthy.
   6. Waits for every Application to become Synced/Healthy.

   From then on ArgoCD owns everything in `k8s/apps/`.

4. **Open the entry point.** Bootstrap tries to map the `*.local`
   hostnames for you; if it couldn't, run `make setup-hosts`. Leave the
   port-forward running in its own terminal:
   ```bash
   make ingress-forward # ingress-nginx -> localhost:8080
   ```
   Then browse `http://wallet.local:8080`, `http://argocd.local:8080`
   (`make argocd-password` prints the login) and
   `http://grafana.local:8080`.

5. **Verify the deployment:**
   ```bash
   kubectl get applications -n argocd             # every app Synced / Healthy
   kubectl get pods -n crypto-wallet-app
   kubectl get externalsecrets -A                 # SecretSynced = True
   kubectl get clusterpolicy                      # Kyverno policy Ready
   make test-load K6_MODE=cluster                 # in-cluster k6 run → Grafana "Performance & Load" dashboard
   ```

6. **Ship a change.** Open a PR. Once it merges, CI builds the images and
   pins them, and ArgoCD rolls them out (see [CI/CD](#cicd)). `make build`
   pushes images manually if you ever need it.

7. **Tear down.** This destroys the Terraform-provisioned AWS
   infrastructure and auto-approves the destroy:
   ```bash
   make down
   ```

## Local vs. Production Traffic Routing

In a production deployment, the ingress-nginx controller's Service would
be `type: LoadBalancer`. That provisions an AWS **ALB/NLB** with a public
IP, and a DNS record (e.g. `wallet.example.com`) points at it:

```
Internet -> DNS -> Cloud LB (ALB/NLB) -> ingress-nginx -> frontend -> {order,wallet}-service
```

This project runs on a **real EKS cluster** but keeps the ingress-nginx
Service as `ClusterIP` on purpose (see `k8s/apps/ingress-nginx-app.yaml`).
That avoids paying for a publicly routable ELB in a portfolio environment.
`make ingress-forward` stands in for the public entry point instead:

```
kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx 8080:80
```

This is the same L7 entry point that production traffic would hit, reached
over a port-forward tunnel instead of a LoadBalancer IP. The Ingress
(`k8s/apps/ingress/wallet-ingress.yaml`) routes purely on the `Host`
header (`host: wallet.local`), the same virtual-hosting mechanism a real
DNS name would drive. A script calling `localhost:8080` has no DNS name to
pick a virtual host, so the **k6 tests send an explicit
`Host: wallet.local` header** (`tests/performance/helpers.js`). The load
test therefore exercises the real end-to-end path: ingress host matching,
the frontend's reverse proxy, and HPA scaling of the backends.

## Operations & Makefile Commands

`make help` prints the full, always-current list.

| Command | What it does |
|---|---|
| `make local-up` / `local-smoke` / `local-logs` / `local-down` / `local-clean` | Docker Compose lifecycle (Quickstart A) |
| `make up` / `make down` | Bootstrap or destroy the cloud platform (Quickstart B) |
| `make ingress-forward` | Port-forwards ingress-nginx to `localhost:8080`, the local stand-in for a load balancer |
| `make setup-hosts` | Adds the `*.local` hostnames to `/etc/hosts` |
| `make vault-init` | Re-applies the Vault Terraform config. Safe to re-run |
| `make build` | Builds all service images and pushes them to ECR |
| `make argocd-password` | Prints the ArgoCD admin login for the UI |
| `make test-load` | Runs `load-test.js` against `BASE_URL` (default `http://localhost:8080`) with `Host: wallet.local` |
| `make test-load K6_SCRIPT=spike-test.js` | Runs a specific script: `load-test.js`, `spike-test.js` or `kafka-pipeline-stress.js` |
| `make test-load K6_MODE=cluster` | Runs k6 as an ephemeral in-cluster Pod that hits the `frontend` Service directly and pushes metrics to Prometheus |

To watch autoscaling during a load test:

```bash
kubectl get hpa,pods -n crypto-wallet-app -w
```

## CI/CD

Two GitHub Actions workflows cover the full path from PR to running pods.

**1. PR gate: [`pr-checks.yml`](.github/workflows/pr-checks.yml).** It runs
on every PR to `main`:

| Job | What it checks |
|---|---|
| YAML lint | `yamllint` on every changed YAML file |
| Kustomize build | `kubectl kustomize` on every `kustomization.yaml` in the repo |
| Schema validation | `kubeconform -strict` on all rendered manifests, including ArgoCD, ESO and Kyverno CRD schemas, fully offline |
| Helm values | `helm template` for each chart-sourced ArgoCD Application with its inline `values` |
| **k6 performance sanity** | Creates a throwaway **Kind** cluster, builds the PR's own service images from source, deploys them via [`k8s/overlays/ci`](k8s/overlays/ci) behind ingress-nginx and Kafka, and runs `load-test.js`. The PR fails unless `p95 < 200ms` and error rate `< 1%` |

The Kind overlay differs from production only where a fresh cluster
can't provide something. A plain fixture Secret replaces the Vault-backed
`ExternalSecret`, and Postgres uses Kind's `standard` StorageClass instead
of `gp3`.

**2. Delivery with automated image pinning: [`ci.yml`](.github/workflows/ci.yml).**
It runs on pushes to `main` that touch `services/**`:

1. `build-and-push` builds each service in a matrix and pushes it to ECR
   under two tags: the immutable **commit SHA** and `:latest`.
2. `update-manifests` rewrites the `image:` lines in
   `k8s/components/{wallet-service,order-service,frontend}.yaml` to that
   SHA. It opens a `chore/pin-images-<sha>` PR, squash-merges it itself,
   and deletes the branch.
3. ArgoCD detects the manifest change and rolls the new pods out.

Pinning to the SHA is what makes deployments work. ArgoCD only reacts to a
change in git, and a re-pushed `:latest` never changes the manifest. The
pin also makes every running image traceable to a commit and revertible
with `git revert`. The pin lands through a PR rather than a direct push
because the `main` branch ruleset applies to CI too.
[architecture.md](architecture.md#9-cicd-pipeline-and-automated-image-pinning)
has the sequence diagram.

## Autoscaling & Resilience Strategy

Each of `frontend`, `order-service` and `wallet-service` has its own
`HorizontalPodAutoscaler` (`k8s/components/hpa.yaml`) with a **70%** CPU
target, `minReplicas: 1` and `maxReplicas: 3`. metrics-server provides the
`metrics.k8s.io` API that the HPAs poll. The ApplicationSet ignores
`spec.replicas` on these Deployments (`ignoreDifferences`), so `selfHeal`
doesn't fight the HPA.

Resource limits are mandatory, not advisory. Kyverno's
`require-resource-limits` ClusterPolicy rejects any Pod outside
`kube-system`, `argocd`, `kyverno` and `monitoring` that is missing CPU or
memory limits.

The three k6 scripts test the system from different angles:

- **`load-test.js`**: a realistic user journey (get balance → place order
  → poll until processed), ramped from 5 to 100 VUs over 3 minutes, held,
  then ramped down. This shape should drive a clean, gradual HPA
  scale-out.
- **`spike-test.js`**: 0 to 300 VUs in 15 seconds. Its thresholds are
  *expected* to fail. The goal is to find where and how the stack breaks
  (slow responses, hard errors or OOMKills).
- **`kafka-pipeline-stress.js`**: a fixed arrival-rate firehose aimed at
  the Kafka pipeline. It measures the end-to-end lag from order to updated
  balance.

**Known capacity ceiling:** each `t3.medium` node can hold at most
**17 pods**, because of the AWS VPC-CNI IP limit without prefix
delegation. If every HPA scales toward `maxReplicas` at once, some pods
stay `Pending` ("Too many pods") before CPU or memory runs out. This is a
known cluster-sizing limit, not a bug in the autoscaling config.

## Security Model

- **No plaintext secrets in git.** Runtime credentials (Postgres, Grafana
  admin, ArgoCD's repo credential) live in Vault. ESO syncs them into
  Kubernetes Secrets through `ClusterSecretStore`s, each bound to its own
  narrowly scoped Vault role and policy.
- **Gitignored local inputs.** `secrets.env`, `.env`, `*.tfvars`,
  `backend.hcl`, Terraform state and the bootstrap repo Secret are all
  ignored. Only `.example` templates are tracked.
- **Remote, encrypted Terraform state.** State lives in an S3 bucket with
  versioning, encryption and blocked public access, with a DynamoDB lock
  table.
- **Admission control.** Kyverno runs in Enforce mode, and every
  `kubeconform` and `helm template` check runs on each PR.
- **Protected `main`.** Every change goes through a PR, including CI's
  own image pins.

Some settings were chosen for a demo environment and would change in
production: Vault runs in dev mode, ingress is reached over a
port-forward, and Kafka uses PLAINTEXT. The
[production-hardening section in architecture.md](architecture.md#production-hardening-roadmap)
lists them.

## Development & Contributing Workflow

Nobody pushes directly to `main`. Every change (manifests, Terraform,
services, docs) goes through a `feat/<task-name>` or `fix/<task-name>`
branch and a Pull Request opened with `gh pr create`. This also applies
to changes made by AI and automation tooling.
[PR Checks](.github/workflows/pr-checks.yml) must pass before merge. Any
live-cluster testing follows the ArgoCD `selfHeal` pause/restore protocol
described in [CONTRIBUTING.md](CONTRIBUTING.md).
