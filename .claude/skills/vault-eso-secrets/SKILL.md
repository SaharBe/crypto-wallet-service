---
name: vault-eso-secrets
description: >-
  Triage secret delivery in this cluster: an ExternalSecret not SecretSynced, a
  ClusterSecretStore not Ready, "secret not found" (crypto-db-secret,
  grafana-admin-credentials, private-repo-creds), Vault 403 permission denied,
  Vault Kubernetes-auth login failures, or credentials that work in Vault but
  not in the pod. Walks the chain ExternalSecret → ClusterSecretStore →
  ServiceAccount → Vault role → Vault policy → KV path.
---

# Vault + ESO secrets: triage runbook

**Never read, print or paste secret values.** Don't run `kubectl get secret
-o yaml/json`, `vault kv get` without `-field` piped somewhere safe, or
`make argocd-password` in the agent session. Check that a secret
**exists** (which keys, the timestamps), not what it contains. Radar's
identity can't read Secrets, by design.

## The chain (each store has exactly one consumer)

| ClusterSecretStore | Logs in as SA (ns) | Vault role → policy | Reads KV path | ExternalSecret → target Secret |
|---|---|---|---|---|
| `vault-crypto-app` | `crypto-sa` (`crypto-wallet-app`) | `crypto-app-role` → `crypto-app-policy` | `secret/data/crypto-db` | `crypto-db-external-secret` → `crypto-db-secret` (crypto-wallet-app) |
| `vault-monitoring` | `grafana-secrets-sa` (`monitoring`) | `monitoring-role` → `monitoring-policy` | `secret/data/monitoring/grafana` | `grafana-admin-credentials` (monitoring) |
| `vault-argocd-repo` | `argocd-repo-reader` (`argocd`) | `argocd-repo-role` → `argocd-repo-policy` | `secret/data/argocd-repo-creds` | `argocd-repo-external-secret` → `private-repo-creds` (argocd) |

Sources: `k8s/components/external-secret.yaml`, `k8s/apps/grafana-secret.yaml`,
`k8s/apps/argocd-repo-secret.yaml`, `terraform/vault-config/main.tf`
(roles and secrets) and `terraform/modules/vault-config` (one read-only policy
per role, scoped to exactly its paths).

Vault itself: Helm app `vault`, pod `vault-0` in namespace `vault`, **dev mode**
(in-memory storage, KV v2 pre-mounted at `secret/`). ESO 2.x
(`external-secrets.io/v1`) in namespace `external-secrets`.

## Check order

### 1. Where in the chain does it break?

```bash
kubectl get clustersecretstore                    # READY / STATUS
kubectl get externalsecret -A                     # STATUS SecretSynced, READY True
kubectl describe externalsecret <name> -n <ns> | sed -n '/Status/,$p'
kubectl get secret <target> -n <ns>               # existence only (no -o yaml)
```

Radar: `get_resource` on the ClusterSecretStore / ExternalSecret (conditions
+ events), `issues` with `kind: ExternalSecret`.

### 2. Map the error message to a cause

| Message (store or ExternalSecret condition / ESO logs) | Cause | Fix |
|---|---|---|
| `permission denied` / `403` on login | Vault role not bound to this SA + namespace, or the role doesn't exist | `terraform/vault-config` role must bind exactly the store's `serviceAccountRef`. Re-run `make vault-init` (ask first) |
| `403` on **read** after a successful login | The role's policy doesn't cover that path (wrong store for the secret, as when grafana once used `crypto-app-role`) | Point the ExternalSecret at the right store, or add the path to that module's `secrets` |
| `secret not found` / `could not get secret data` | KV path or `property` doesn't exist. Note: `crypto-db` and `argocd-repo-creds` use a **mount-relative** key, while grafana uses the full `secret/data/...` form. Both work, so keep each file consistent | Fix the `remoteRef.key`/`property`, or write the value with Terraform |
| `serviceaccounts "X" not found` | The store's SA hasn't been created yet (sync-wave ordering) or was renamed | Check the SA manifest and its wave |
| `connection refused` / `no such host vault.vault.svc` | `vault-0` down or restarting | See step 3 |
| CRD / `no matches for kind ClusterSecretStore` | ESO not installed yet (wave 0) | Wait for `external-secrets` app; check it uses `ServerSideApply=true` |

### 3. Vault restarted? (dev mode loses everything)

Vault runs in **dev mode with in-memory storage**. A restart of `vault-0`
wipes every KV secret, role, policy **and the Kubernetes auth backend**. Every
store then fails at once. Signals: all three stores not Ready together,
`vault-0` restart count > 0 or a recent age, and login errors like `no handler
for route "auth/kubernetes/login"`.

```bash
kubectl get pod vault-0 -n vault
```

Recovery is `make vault-init` (Terraform re-creates the auth backend, roles,
policies and secrets from `secrets.env`). **Ask the user to run it, or get
approval first.** Existing K8s Secrets keep their last values until the next
`refreshInterval` (1h), so running pods usually aren't hit right away.

### 4. Secret synced, but the app still fails

- Pods read secrets as env vars only at start. A rotated value in Vault
  reaches a running pod only after a restart.
- Postgres keeps the password it was **initialised** with on its PVC.
  Changing `crypto-db` in Vault doesn't change the DB user's password. The
  symptom is `password authentication failed` in wallet-service.
- `private-repo-creds` wrong or missing: ArgoCD repo-sourced apps get
  `ComparisonError`. Use the **argocd-out-of-sync** skill.

## Guardrails

- Never use `"*"` for `bound_service_account_names` and never add extra
  namespaces to a role to "make it work". Bind exactly the store's
  `serviceAccountRef` (SEC-411).
- Never fall back to a plain `Secret` manifest, Sealed Secrets, or values in
  Helm `values`. The only exception is the CI fixture
  `k8s/overlays/ci/ci-db-secret.yaml`.
- `make vault-init`, Vault pod restarts, deleting ExternalSecrets or their
  target Secrets: **ask first**.

## Finish

Name the broken link in the chain (store / SA / role / policy / path), quote
the exact condition message, state which consumers are affected, and propose
the git change (Terraform or manifest), plus any `make vault-init` the user
needs to run.
