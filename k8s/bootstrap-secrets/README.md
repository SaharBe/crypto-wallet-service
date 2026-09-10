# k8s/bootstrap-secrets/

Bootstrap-time secret manifests that are **not** synced by ArgoCD.

ArgoCD only reconciles `k8s/apps/` (via `k8s/root-app.yaml`) and the paths
listed in `k8s/apps/crypto-wallet-appset.yaml` (`k8s/components/`, etc.).
Anything in this directory is applied manually or kept purely as reference.

| File | Purpose |
| --- | --- |
| `repo-secret.yaml.example` | Shape reference for the bootstrap-time `private-repo-creds` repository Secret. `bootstrap.sh` (Step 4) generates the real object from `secrets.env`; once ArgoCD + ESO are up, `k8s/apps/argocd-repo-secret.yaml` takes ownership. Copy to `repo-secret.yaml` (gitignored) only if you need to apply it by hand. |
| `crypto-sa-default.yaml` | Standalone copy of the `crypto-sa` ServiceAccount in `default`, used for Vault Kubernetes auth. The synced source of truth is `k8s/components/service-account.yaml`; this file is a manual `kubectl apply` fallback for a cluster without ArgoCD. |
