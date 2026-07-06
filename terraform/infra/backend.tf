# Bucket/table names are supplied via backend.hcl (partial config) rather
# than hardcoded here, since they come from terraform/state-backend's
# outputs and shouldn't be duplicated across roots.
#
#   terraform init -backend-config=backend.hcl -migrate-state
terraform {
  backend "s3" {
    key     = "infra/terraform.tfstate"
    encrypt = true
  }
}
