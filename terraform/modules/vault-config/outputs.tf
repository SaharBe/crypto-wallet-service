output "role_name" {
  description = "Vault Kubernetes auth role name, for reference by SecretStore/ClusterSecretStore resources."
  value       = vault_kubernetes_auth_backend_role.this.role_name
}

output "kv_mount_path" {
  value = var.kv_mount_path
}
