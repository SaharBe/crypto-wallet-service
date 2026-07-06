locals {
  # Secret names aren't sensitive, only their values — unwrap just the keys
  # so they can drive for_each/string interpolation below (Terraform forbids
  # for_each over anything derived from a sensitive value).
  secret_names = nonsensitive(keys(var.secrets))

  # Scope the policy to exactly the secrets this module instance writes,
  # not a wildcard over the whole mount — keeps each role least-privilege
  # even though every role shares the same "secret" KV mount.
  policy_document = join("\n", [
    for name in local.secret_names : <<-EOT
      path "${var.kv_mount_path}/data/${name}" {
        capabilities = ["read"]
      }
    EOT
  ])
}

resource "vault_policy" "this" {
  name   = var.policy_name
  policy = local.policy_document
}

resource "vault_kubernetes_auth_backend_role" "this" {
  backend                          = var.auth_backend
  role_name                        = var.role_name
  bound_service_account_names      = var.bound_service_account_names
  bound_service_account_namespaces = var.bound_service_account_namespaces
  token_policies                   = [vault_policy.this.name]
  token_ttl                        = var.token_ttl
}

resource "vault_mount" "kv" {
  count = var.manage_kv_mount ? 1 : 0

  path = var.kv_mount_path
  type = "kv-v2"
}

resource "vault_kv_secret_v2" "this" {
  for_each = toset(local.secret_names)

  mount     = var.kv_mount_path
  name      = each.value
  data_json = jsonencode(var.secrets[each.value])

  depends_on = [vault_mount.kv]
}
