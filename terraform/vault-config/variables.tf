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
