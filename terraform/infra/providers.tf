terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  # One tag set for everything this root creates. `make verify-clean`
  # (scripts/verify-clean.sh) finds leftovers by Project=crypto-wallet, so a
  # resource without it is invisible to the post-destroy check. Before this,
  # the EKS module said Project=crypto-wallet-idp, the VPC module said
  # crypto-wallet-service and ECR/IAM had no Project tag at all; verify-clean
  # still matches those legacy values so pre-existing orphans are caught too.
  common_tags = {
    Project     = "crypto-wallet"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = "us-east-1"

  # default_tags reaches every resource the provider creates directly
  # (VPC, NAT, EIP, EKS, IAM, ECR, KMS, log group, launch template), with no
  # per-resource tags blocks to drift apart. It does NOT reach what AWS
  # launches on our behalf (node instances, their root volumes and ENIs):
  # those get the same tags via the node group's launch_template_tags in
  # eks.tf. EBS CSI and Kubernetes-created load balancers are tagged from
  # the Kubernetes side (k8s/apps/ebs-storageclass.yaml,
  # k8s/apps/ingress-nginx-app.yaml).
  default_tags {
    tags = local.common_tags
  }
}
