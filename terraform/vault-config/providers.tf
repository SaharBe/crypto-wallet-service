terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "vault" {
  # Reached via `kubectl port-forward svc/vault -n vault 8200:8200`, run by
  # bootstrap.sh — this root executes off-cluster, so it can't resolve
  # Vault's in-cluster Service DNS name directly.
  address = var.vault_address
  token   = var.vault_token

  # Dev-mode root token; production would swap this provider auth for
  # something short-lived (e.g. an OIDC/JWT login) instead of a static token.
  skip_child_token = true
}
