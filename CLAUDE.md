# CLAUDE.md

Guidance for Claude Code (and other AI/dev automation) working in this
repository. These rules are binding: they mirror [CONTRIBUTING.md](CONTRIBUTING.md)
and the gates in [.github/workflows/pr-checks.yml](.github/workflows/pr-checks.yml).
When this file and those disagree, the workflow files are the source of truth;
fix this file in the same PR.

---

## 1. Project overview

`crypto-wallet-service` is a GitOps-managed internal developer platform that
runs a small crypto-wallet application on Kubernetes (AWS EKS in production,
Kind in CI).

| Layer | Tooling | Where it lives |
| --- | --- | --- |
| Infrastructure | Terraform (VPC, EKS, ECR, EBS CSI, remote state) | `terraform/infra`, `terraform/state-backend` |
| Secrets | HashiCorp Vault + External Secrets Operator (ESO) | `k8s/apps/vault.yaml`, `k8s/apps/external-secrets.yaml`, `terraform/vault-config` |
| Delivery | ArgoCD App-of-Apps (`k8s/root-app.yaml` → `k8s/apps/`) + one ApplicationSet | `k8s/apps/crypto-wallet-appset.yaml` |
| Manifests | Kustomize (base in `k8s/components`, CI overlay in `k8s/overlays/ci`) | `k8s/` |
| Policy | Kyverno (`require-resource-limits`, **Enforce** mode) | `k8s/apps/kyverno-policies/` |
| Network isolation | NetworkPolicies, default-deny ingress in `crypto-wallet-app`; enforced by the VPC CNI add-on (`enableNetworkPolicy`) | `k8s/components/network-policies.yaml`, `terraform/infra/eks.tf` |
| Messaging | Kafka (Bitnami chart) + kafka-exporter | `k8s/apps/kafka-app.yaml`, `k8s/apps/kafka/` |
| Observability | kube-prometheus-stack (Prometheus + Grafana), dashboards as plain JSON | `k8s/apps/monitoring-app.yaml`, `k8s/apps/monitoring/` |
| Ingress | ingress-nginx, `*.local` hosts via port-forward | `k8s/apps/ingress/` |
| Services | `wallet-service`, `order-service` (Node.js), `frontend` (nginx) | `services/` |
| Performance | k6 (local or ephemeral in-cluster Pod, metrics → Prometheus remote-write) | `tests/performance/` |
| CI/CD | `pr-checks.yml` (PR gate), `ci.yml` (build → ECR → pin image tags on `main`) | `.github/workflows/` |

Further reading: [README.md](README.md), [architecture.md](architecture.md),
[tests/performance/README.md](tests/performance/README.md),
[k8s/bootstrap-secrets/README.md](k8s/bootstrap-secrets/README.md).

### How changes reach the cluster

1. A PR merges to `main`.
2. ArgoCD (`automated: { prune: true, selfHeal: true }`) syncs `k8s/apps/`
   and every path in the ApplicationSet (`k8s/components`, `k8s/apps/monitoring`,
   `k8s/apps/kafka`).
3. For service code, `ci.yml` builds images, pushes them to ECR, and its
   `update-manifests` job pins the new commit-SHA image tag in
   `k8s/components/*.yaml` through a `chore/pin-images-<sha>` PR that it opens
   and squash-merges itself. That merge is what makes ArgoCD roll pods.

**Consequence:** any live `kubectl edit/apply` that isn't committed on `main`
is reverted by `selfHeal`. Git is the only durable way to change the cluster.

---

## 2. DOs: required and encouraged

### Branching and PRs
- **Start every task on a dedicated branch off `main`**:
  `feat/<task-name>` for new capability, `fix/<task-name>` for bugs/regressions.
  Check `git branch --show-current` first; if you're on `main`, or on a branch
  that belongs to a different task, create a new one.
- Commit on the branch, `git push -u origin <branch>`, and open the PR with
  `gh pr create --base main`. The PR body must say **what changed and how it
  was validated** (command output, `kubectl` checks, k6 results).
- Use Conventional Commit-style messages, matching history:
  `feat(observability): ...`, `fix(k8s): ...`, `refactor(...)`, `chore(...)`.

### Validate locally before every push
Run the same checks CI runs (Section 4.1). All must pass:
1. `yamllint -c .yamllint.yml` on changed YAML (max line 120, no `---` required).
2. `kubectl kustomize` on **every** `kustomization.yaml` under `k8s/`.
3. `kubeconform -strict` on the rendered output, including CRD schemas
   (ArgoCD, ESO, Kyverno).
4. `python3 scripts/ci/validate_argocd_helm_apps.py k8s/apps` when you touch a
   Helm-sourced ArgoCD Application's chart, version or `values`.

### Manifests and Kustomize
- Put app workloads in `k8s/components/` and **register each new file in
  `k8s/components/kustomization.yaml`**. An unlisted file is never deployed.
- Environment-specific differences go in an overlay (`k8s/overlays/<env>/`)
  as patches or `images:` rewrites. Don't fork base manifests. If a base change
  breaks the CI overlay (e.g. a new ExternalSecret or a `gp3` PVC), update
  `k8s/overlays/ci/kustomization.yaml` in the same PR.
- New ArgoCD-managed paths: add an element to the ApplicationSet's list
  generator, or a standalone `Application` in `k8s/apps/` when it needs its
  own sync-wave or `ignoreDifferences` (see `kyverno-policies-app.yaml`).
  Keep `syncPolicy.retry` and `SkipDryRunOnMissingResource=true` consistent
  with existing apps.
- **Every container outside `kube-system`, `argocd`, `kyverno` and `monitoring`
  must set `resources.limits.cpu` and `resources.limits.memory`.** Kyverno
  rejects the Pod otherwise. Set requests too.
- `crypto-wallet-app` is **default-deny for ingress**. A new workload there,
  or a new caller of an existing one, gets no traffic until you add a
  matching allow rule to `k8s/components/network-policies.yaml`. Open one
  hop at a time (source selector + port), never an allow-all.
- Pin images to immutable tags, never `:latest`, for anything ArgoCD deploys.
  Don't hand-edit the ECR image tags in `k8s/components/{wallet-service,order-service,frontend}.yaml`;
  `ci.yml` owns them.
- HPAs own `spec.replicas` for `wallet-service`, `order-service` and `frontend`
  (ignored in the ApplicationSet's `ignoreDifferences`). Tune scaling in
  `k8s/components/hpa.yaml`, not via Deployment replica counts.
- Grafana dashboards are plain `.json` files in `k8s/apps/monitoring/dashboards/`,
  wired up via `configMapGenerator` with `grafana_dashboard: "1"` and
  `disableNameSuffixHash: true`. Don't inline dashboard JSON into a YAML
  ConfigMap.
- Match the existing comment style: explain **why** a non-obvious setting
  exists (sync waves, ignoreDifferences, patches), next to the setting.

### Keep docs in sync (same PR)
- Before opening a PR, grep README.md, architecture.md and CLAUDE.md for
  what you changed (file paths, component names, make targets, namespaces,
  ports, Vault roles/stores) and update any statement that is no longer true.
  Do this for every change, however small.
- Adding or removing a component: also update the README tech-stack table,
  the CLAUDE.md overview table and the relevant architecture.md diagram.
- Closing a gap listed in architecture.md's production-hardening roadmap:
  update or remove that row.
- Prefer describing structure and linking to the source file over copying
  volatile details (chart versions, replica counts, image tags) into docs.
- State the result in the PR body: which docs were updated, or
  "Docs: no changes needed".
- Exempt: `ci.yml`'s automated `chore/pin-images-<sha>` PRs.

### Live-cluster validation, when a change needs it
For sizing, autoscaling, probes and anything worth watching under real load,
follow CONTRIBUTING.md's procedure. Commit on the branch first, then:

```bash
# 1. Pause selfHeal on ONLY the Application being validated
kubectl patch application <app> -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2. Apply the branch's rendered manifests and validate
kubectl apply -k k8s/components
kubectl get hpa,pods -n crypto-wallet-app -w

# 3. ALWAYS restore selfHeal before ending the task
kubectl patch application <app> -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Cluster capacity caveat: the EKS cluster runs 3× `t3.medium` nodes with a
hard ceiling of **17 pods per node** (VPC-CNI IP limit). If several HPAs scale
toward `maxReplicas` at once, pods can stay `Pending` with "Too many pods".
Report this to the user rather than quietly working around it.

---

## 3. DON'Ts: hard guardrails

### Git
- **NEVER commit or push directly to `main`**, and never bypass branch
  protection: no `--force` to `main`, no admin merges, no `--no-verify`.
  The "Protect main branche" ruleset enforces this for everyone, CI included:
  `ci.yml`'s `update-manifests` job lands its image pins through a PR that it
  merges itself. That auto-merge is a narrow automated exception, not a precedent.
- **NEVER merge a PR yourself** unless the user explicitly asks.
- Pushes that touch `.github/workflows/*.yml` need the `workflow` OAuth scope.
  If GitHub rejects the push, ask the user to run
  `gh auth refresh -h github.com -s workflow` (interactive). Don't try to
  work around it.

### Secrets
- **NEVER hardcode secrets or plaintext credentials** in manifests, Helm
  `values`, Terraform, scripts, Dockerfiles, docs or commit messages.
- The only supported pattern is **Vault → ESO**: store the value in Vault
  (`terraform/vault-config`, run via `make vault-init`), then reference it with
  an `ExternalSecret` against an existing `ClusterSecretStore`
  (`vault-crypto-app`, `vault-monitoring`, `vault-argocd-repo`), or add a
  dedicated Vault role and store for a new consumer. See `k8s/components/external-secret.yaml` and
  `k8s/apps/grafana-secret.yaml`. The repo uses no Sealed Secrets and no
  plain `Secret` objects, apart from the throwaway CI fixture
  `k8s/overlays/ci/ci-db-secret.yaml`.
- Every Vault Kubernetes-auth role binds **exactly** the ServiceAccount and
  namespace its `ClusterSecretStore` logs in with (`serviceAccountRef`).
  Never use `"*"` for `bound_service_account_names` or add namespaces that
  don't need access.
- Never commit `secrets.env`, `k8s/bootstrap-secrets/repo-secret.yaml`,
  `terraform.tfvars`, `backend.hcl` or any `*.tfstate`. Only the `.example`
  files belong in git.
- Don't print secret values (Vault tokens, `ARGOCD_ADMIN_PASSWORD`, DB
  passwords, GitHub PATs) into PR bodies, logs or chat. `make argocd-password`
  is for the user's own terminal.

### Cluster hygiene
- **NEVER leave dangling test resources.** Anything you create for a test
  (k6 Pods/ConfigMaps, debug Pods, temporary Deployments, Kafka topics or
  consumer groups, port-forwards) must be cleaned up before the task ends.
  `run-in-cluster.sh` cleans up after itself; verify with
  `kubectl get pods,cm -n crypto-wallet-app | grep k6`.
- Don't pollute shared state: no ad-hoc Kafka topic deletion or offset
  resets, no Prometheus TSDB deletion or config changes outside git, and no
  manual edits to Grafana dashboards that you don't export back into
  `dashboards/*.json`.
- **NEVER leave an ArgoCD Application with `selfHeal` disabled.**
- Don't run destructive or cost-impacting commands without explicit user
  confirmation in the current conversation: `make down` / `terraform destroy`,
  `terraform apply` on `terraform/infra`, `kubectl delete namespace`,
  `kubectl delete application`, `argocd app delete`, ECR image deletion, PVC
  deletion (Postgres data).
- Don't weaken guardrails to make something pass: no exempting namespaces in
  the Kyverno policy, no switching it to `Audit`, no disabling PR-check jobs,
  no relaxing `.yamllint.yml` just to get a file through, no allow-all or
  namespace-wide NetworkPolicy to get traffic flowing.
- Don't run high-load k6 scenarios (`spike-test.js`,
  `kafka-pipeline-stress.js`) against the live cluster unless the user asks.

---

## 4. Common commands

All `make` targets run from the repo root. `make help` lists them.
`secrets.env` is sourced automatically when present (copy from
`secrets.env.example`).

### 4.1 Local validation (mirrors `pr-checks.yml`)

```bash
# YAML lint: files changed vs main
git diff --name-only --diff-filter=ACMR main...HEAD -- '*.yaml' '*.yml' \
  | xargs -r yamllint -c .yamllint.yml

# Kustomize build: every kustomization in the repo
find k8s -name kustomization.yaml -print0 \
  | xargs -0 -n1 dirname \
  | while read -r d; do echo "== $d"; kubectl kustomize "$d" >/dev/null || echo "FAILED: $d"; done

# kubeconform: offline schema validation, including CRDs
mkdir -p /tmp/rendered
find k8s -name kustomization.yaml -print0 | while IFS= read -r -d '' k; do
  d=$(dirname "$k"); kubectl kustomize "$d" > "/tmp/rendered/$(echo "$d" | tr / _).yaml"
done
for f in k8s/apps/*.yaml; do echo '---'; cat "$f"; echo; done > /tmp/rendered/apps-root.yaml
for f in k8s/apps/kyverno-policies/*.yaml; do echo '---'; cat "$f"; echo; done > /tmp/rendered/kyverno-policies.yaml
REPO_URL='https://example.invalid/placeholder.git' envsubst < k8s/root-app.yaml > /tmp/rendered/root-app.yaml
kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/rendered/*.yaml

# Helm values on ArgoCD Applications (needs helm + pyyaml)
python3 scripts/ci/validate_argocd_helm_apps.py k8s/apps

# Terraform, when touched
terraform -chdir=terraform/infra fmt -check && terraform -chdir=terraform/infra validate
```

### 4.2 Performance tests (k6)

```bash
# In-cluster (preferred for real numbers): ephemeral k6 Pod hits the frontend
# Service directly and pushes metrics to Prometheus (testid=<pod name>)
make test-load K6_MODE=cluster                                  # load-test.js
make test-load K6_MODE=cluster K6_SCRIPT=spike-test.js
make test-load K6_MODE=cluster K6_SCRIPT=kafka-pipeline-stress.js

# Local: through the ingress port-forward (run `make ingress-forward` first)
make test-load
make test-load K6_SCRIPT=spike-test.js BASE_URL=http://localhost:8080 HOST_HEADER=wallet.local

# Skip the Prometheus push (summary only)
K6_PROMETHEUS_RW_SERVER_URL='' make test-load K6_MODE=cluster
```

Watch results on the **"Crypto Wallet - Performance & Load"** Grafana
dashboard, filtered by test id.

### 4.3 ArgoCD

```bash
make argocd-password                         # admin credentials for the UI
argocd login argocd.local:8080 --grpc-web    # after `make ingress-forward` + `make setup-hosts`

argocd app list
argocd app get crypto-wallet-app
argocd app diff crypto-wallet-app            # live vs git
argocd app sync crypto-wallet-app            # also: monitoring-custom, kafka-exporter,
argocd app sync root-application             #       monitoring-stack, kyverno-policies, ...
argocd app wait crypto-wallet-app --health --timeout 300

# Without the argocd CLI
kubectl get applications -n argocd
kubectl -n argocd annotate application crypto-wallet-app \
  argocd.argoproj.io/refresh=hard --overwrite
```

`argocd app sync` deploys what's on `main` (`targetRevision: HEAD`), not your
branch. Use the live-validation procedure in Section 2 to test branch changes.

### 4.4 Access and port-forwarding

```bash
make setup-hosts       # once: argocd/grafana/vault/wallet.local -> 127.0.0.1
make ingress-forward   # ingress-nginx -> localhost:8080; then browse http://<host>.local:8080

# Direct port-forwards (bypassing ingress)
kubectl port-forward svc/monitoring-stack-grafana 3000:80 -n monitoring                  # Grafana
kubectl port-forward svc/monitoring-stack-kube-prom-prometheus 9090:9090 -n monitoring   # Prometheus
kubectl port-forward svc/vault 8200:8200 -n vault                                        # Vault
kubectl port-forward svc/frontend 8081:80 -n crypto-wallet-app                           # frontend (use HOST_HEADER='')
```

Stop every port-forward you start (Ctrl+C / `kill %1`) before finishing.

### 4.5 Platform lifecycle (confirm with the user first)

```bash
make up            # full bootstrap via ./bootstrap.sh
make vault-init    # (re)configure Vault via Terraform, safe to re-run
make build         # build & push all service images to ECR
make down          # DESTRUCTIVE: terraform destroy on terraform/infra (auto-approved)
```

### 4.6 Quick health checks

```bash
kubectl get pods -A | grep -v -E 'Running|Completed'
kubectl get hpa -n crypto-wallet-app
kubectl get externalsecrets -A                 # SecretSynced should be True
kubectl get clusterpolicy                       # Kyverno policies Ready
kubectl get networkpolicy -n crypto-wallet-app  # default-deny + 3 allow rules
kubectl get events -A --field-selector reason=PolicyViolation
```

---

## 5. Definition of done (checklist for every task)

- [ ] Work is on a `feat/...` or `fix/...` branch, not `main`.
- [ ] yamllint, kustomize build, kubeconform (and helm-values check if relevant) pass locally.
- [ ] New manifests are listed in their `kustomization.yaml`; containers have CPU/memory limits.
- [ ] No secrets or credentials in the diff.
- [ ] README.md / architecture.md / CLAUDE.md checked against the change; the PR body says
      what was updated or "Docs: no changes needed".
- [ ] Every test resource, port-forward and paused `selfHeal` has been cleaned up or restored.
- [ ] Branch pushed and PR opened with `gh pr create`, with a validation summary in the body.
