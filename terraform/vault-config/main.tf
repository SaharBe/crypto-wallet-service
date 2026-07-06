# Replaces the `kubectl exec vault ...` block that used to live in
# bootstrap.sh. Run after Vault is deployed (by ArgoCD) and reachable
# (see providers.tf) — see repo root README / bootstrap.sh for ordering.

# Enabling/configuring the Kubernetes auth backend is a cluster-wide
# singleton — Vault only allows one mount per path, so this lives once at
# root instead of inside modules/vault-config (which is instantiated once
# per role below).
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = var.kubernetes_host
}

module "crypto_app" {
  source     = "../modules/vault-config"
  depends_on = [vault_kubernetes_auth_backend_config.this]

  auth_backend_path                = vault_auth_backend.kubernetes.path
  policy_name                      = "crypto-app-policy"
  role_name                        = "crypto-app-role"
  bound_service_account_names      = ["crypto-sa"]
  bound_service_account_namespaces = ["default"]

  # server.dev.enabled=true in the Vault Helm values already pre-mounts
  # "secret/" as KV v2 — creating it again here would error.
  manage_kv_mount = false

  secrets = {
    "crypto-db" = {
      username = var.db_username
      password = var.db_password
    }
  }
}

module "argocd_repo" {
  source     = "../modules/vault-config"
  depends_on = [vault_kubernetes_auth_backend_config.this]

  auth_backend_path                = vault_auth_backend.kubernetes.path
  policy_name                      = "argocd-repo-policy"
  role_name                        = "argocd-repo-role"
  bound_service_account_names      = ["argocd-repo-reader"]
  bound_service_account_namespaces = ["argocd"]

  manage_kv_mount = false

  secrets = {
    "argocd-repo-creds" = {
      username = var.github_username
      password = var.github_pat
    }
  }
}
