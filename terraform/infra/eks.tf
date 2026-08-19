# שימוש במודול ה-EKS הרשמי של AWS
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.30"

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

  tags = {
    Environment = "production"
    Project     = "crypto-wallet-idp"
    ManagedBy   = "OpenTofu"
  }
}