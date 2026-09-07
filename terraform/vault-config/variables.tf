variable "kubernetes_host" {
  description = "API server URL Vault uses to validate service account tokens during Kubernetes auth login."
  type        = string
  default     = "https://kubernetes.default.svc:443"
}

variable "vault_address" {
  description = "Vault API address reachable from wherever Terraform runs (bootstrap.sh port-forwards this)."
  type        = string
  default     = "http://127.0.0.1:8200"
}

variable "vault_token" {
  description = "Vault token used by Terraform to configure Vault. Dev-mode root token during bootstrap."
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "Initial crypto-db username, written to Vault at secret/crypto-db."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Initial crypto-db password, written to Vault at secret/crypto-db."
  type        = string
  sensitive   = true
}

variable "repo_url" {
  description = "Canonical Git repository URL for this platform. Written to Vault at secret/argocd-repo-creds (key \"url\") so ESO can populate it in ArgoCD's repository Secret — see k8s/apps/argocd-repo-secret.yaml. Passed as TF_VAR_repo_url from secrets.env by bootstrap.sh; the default is the fallback single source of truth."
  type        = string
  default     = "https://github.com/SaharBe/crypto-wallet-service.git"
}

variable "github_username" {
  description = "GitHub username ESO will expose to ArgoCD's repository credentials Secret."
  type        = string
  sensitive   = true
}

variable "github_pat" {
  description = "GitHub personal access token for ArgoCD to read the private repo, written to Vault at secret/argocd-repo-creds."
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "The admin password for Grafana dashboard"
  type        = string
  sensitive   = true
  default     = "Admin10!"
}