---
name: argocd-out-of-sync
description: >-
  Triage ArgoCD Applications in this repo that are OutOfSync, Unknown,
  Degraded, stuck syncing, flapping, or reverting someone's change: root-application
  (App-of-Apps), the crypto-wallet-apps ApplicationSet (crypto-wallet-app,
  monitoring-custom, kafka-exporter, ai-ops) and the Helm-sourced apps (vault,
  external-secrets, kafka, kyverno, monitoring-stack, ...). Use for
  ComparisonError, "repository not found", sync-wave hangs, ignoreDifferences,
  HPA replica drift, or "my kubectl change disappeared".
---

# ArgoCD out of sync: triage runbook

## How this repo is wired

- `k8s/root-app.yaml` (`root-application`) is applied once by
  `bootstrap.sh` **after `envsubst '${REPO_URL}'`**. It syncs `k8s/apps/`
  from `main` (`targetRevision: HEAD`).
- Everything under `k8s/apps/` is synced **straight from git, with no
  envsubst**. A literal `${REPO_URL}` in any file there reaches ArgoCD
  unrendered.
- `k8s/apps/crypto-wallet-appset.yaml` generates `crypto-wallet-app`
  (`k8s/components`), `monitoring-custom`, `kafka-exporter` and `ai-ops`.
- Every app: `automated: {prune: true, selfHeal: true}`, `retry` limit 10,
  backoff 10s→3m. Repo-sourced apps also set `SkipDryRunOnMissingResource=true`.
- Sync waves in root-application: `-1` the monitoring Namespace, `0` (default)
  vault/external-secrets/kafka/kyverno/..., `1` monitoring-stack, ingress, and
  the ESO trios in `argocd-repo-secret.yaml` / `grafana-secret.yaml`.
  root-application waits for **every** wave-0 resource to be Healthy before
  it creates wave 1.

## Tools

- **Radar MCP**: `issues` (category `gitops_*`), then `diagnose` with
  `kind: application, namespace: argocd`. You get sync/health status,
  conditions, history and the per-resource status.
- **CLI** (read): `argocd app get|diff <app>`, `kubectl get applications -n argocd`.
  `argocd app diff` compares against `main`, not your branch.

## Map the symptom to a cause

### Sync `Unknown` + `ComparisonError`

ArgoCD can't render the desired state. Read the condition message:

- `failed to list refs: repository not found`: compare `spec.source.repoURL`
  with the repo credential's URL. Common causes here:
  - **A literal `${REPO_URL}`** in a file under `k8s/apps/` (only
    `root-app.yaml` is envsubst'd). Fix: put the literal repo URL back in git.
    The Application spec comes from git, so a live patch would be reverted.
  - The `private-repo-creds` Secret (ESO, `vault-argocd-repo`) is missing or
    stale. Use the **vault-eso-secrets** skill.
- `helm template` / `kustomize build` errors: render it locally, the way CI
  does (CLAUDE.md §4.1), and fix the manifest.
- While comparison fails, **nothing is synced or pruned**. Running workloads
  keep running, but new commits (including the image pins from `ci.yml`)
  don't roll out. Say so in the impact statement.

### `OutOfSync` that keeps coming back (flapping)

A controller or webhook mutates the live object after ArgoCD applies it:

- **HPA `spec.replicas`**: already ignored for frontend/order-service/
  wallet-service in the ApplicationSet. A new HPA-scaled Deployment needs its
  own `ignoreDifferences` entry. postgres-db is deliberately not ignored.
- **Kyverno ClusterPolicy defaults**: the webhook injects fields.
  `kyverno-policies-app.yaml` ignores them with `jqPathExpressions`. A known
  open flap is `root-application` toggling on the `kyverno` Application
  (PLAT-509).
- **Kafka KRaft IDs**: `kafka-app.yaml` ignores `kafka-kraft` `/data` and the
  StatefulSet `checksum/secret`, with `RespectIgnoreDifferences=true` (PLAT-518).
- To find the field: `argocd app diff <app>`, or Radar `get_resource
  include=changes`. Fix it with a narrow `ignoreDifferences` (named resource +
  pointer), never a blanket kind-wide rule.

### "My change was reverted"

That's `selfHeal` working. A live `kubectl edit/patch/apply` that isn't on
`main` comes back within seconds (measured ~3 s in PLAT-501). The fix is a PR.
To test a branch on the live cluster, use CLAUDE.md's live-validation procedure
(pause `automated` on **one** app, apply, validate, **always restore**).

### Sync stuck / `Progressing` forever / wave never starts

- Check `status.operationState` (phase, message, retry count) on
  root-application first. Find which wave-0 resource isn't Healthy.
- `namespaces "X" not found` fails the whole root sync. Create the Namespace
  at an earlier wave (pattern: `grafana-secret.yaml`).
- An ExternalSecret that can't sync because its Vault role doesn't exist yet
  must not sit in wave 0. It blocks the gate before `make vault-init` can run.
- A CRD that's missing on first sync: `SkipDryRunOnMissingResource=true`
  must be set on the app.
- `retry` exhausted (10 attempts): after the cause is fixed in git, a
  manual `argocd app sync <app>` restarts it. **Ask first.**

### `Degraded` with sync OK

ArgoCD just reflects workload health. Switch to **pod-not-ready-triage**
(or **kafka-lag-triage** / **vault-eso-secrets**) for the failing resource.

## Forbidden without explicit approval

`kubectl delete application`, `argocd app delete`, removing finalizers,
`argocd app sync --force/--replace/--prune`, hard refresh loops, or leaving
any app with `automated` disabled. Never disable `selfHeal` to "make it stick".

## Finish

List every affected Application, the condition message, the git file and line
that cause it, the blast radius (what isn't reconciling), and the fix as a
PR diff.
