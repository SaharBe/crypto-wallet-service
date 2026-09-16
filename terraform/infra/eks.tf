# שימוש במודול ה-EKS הרשמי של AWS
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.31"

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    app_nodes = {
      min_size     = 1
      max_size     = 3
      desired_size = 3

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      ami_type = "AL2023_x86_64_STANDARD"
    }
  }

  # IRSA role is defined in ebs-csi.tf (needs this module's own
  # oidc_provider_arn/cluster_oidc_issuer_url outputs as inputs — see that
  # file's header for why this doesn't create a dependency cycle).
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
    }
  }

  tags = {
    Environment = "production"
    Project     = "crypto-wallet-idp"
    ManagedBy   = "OpenTofu"
  }
}