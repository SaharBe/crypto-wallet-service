# terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key     = "vault-config/terraform.tfstate"
    encrypt = true
  }
}
