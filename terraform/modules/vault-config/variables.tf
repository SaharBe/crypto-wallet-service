variable "auth_backend" {
  description = <<-EOT
    Path of an already-enabled & configured Vault Kubernetes auth backend
    (see the root module's vault_auth_backend/vault_kubernetes_auth_backend_config
    resources). Auth backend enable/configure is a cluster-wide singleton —
    it must live outside this module, since Vault only allows one mount per
    path and this module is instantiated once per role.
  EOT
  type        = string
}

variable "policy_name" {
  description = "Name of the Vault policy granting read access to the KV secret."
  type        = string
}

variable "role_name" {
  description = "Name of the Vault Kubernetes auth role."
  type        = string
}

variable "bound_service_account_names" {
  description = "Kubernetes ServiceAccounts allowed to assume this role."
  type        = list(string)
}

variable "bound_service_account_namespaces" {
  description = "Namespaces the bound ServiceAccounts must live in."
  type        = list(string)
}

variable "token_ttl" {
  description = "TTL (seconds) of tokens issued for this role."
  type        = number
  default     = 86400
}

variable "kv_mount_path" {
  description = "Path the KV v2 secrets engine is mounted at."
  type        = string
  default     = "secret"
}

variable "manage_kv_mount" {
  description = <<-EOT
    Whether this module should create the KV v2 mount. Leave false when Vault
    already auto-mounts it (e.g. server.dev.enabled=true always pre-mounts
    "secret/") — creating it again would fail with "path already in use".
  EOT
  type        = bool
  default     = false
}

variable "secrets" {
  description = <<-EOT
    Map of KV v2 secrets to write, keyed by secret name (path under
    kv_mount_path). Each value is the map of key/value data stored at that path.
    Example: { "crypto-db" = { username = "myuser", password = "mypassword" } }
  EOT
  type        = map(map(string))
  sensitive   = true
}
