variable "region" {
  description = "AWS region for the state backend resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for the state bucket and lock table names."
  type        = string
  default     = "crypto-wallet"
}
