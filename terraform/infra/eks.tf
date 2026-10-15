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
      ami_type       = "AL2023_x86_64_STANDARD"
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

    # Brings the VPC CNI under EKS add-on management so it can turn on
    # NetworkPolicy enforcement (SEC-410). Until now aws-node was the
    # self-managed copy EKS installs at cluster creation, running with
    # --enable-network-policy=false: every NetworkPolicy in the cluster
    # (k8s/components/network-policies.yaml, plus the ones the ArgoCD and
    # Kafka installs ship) was stored but not enforced.
    #
    # Pinned to the version already running, not most_recent: this change
    # only adopts the DaemonSet and flips one flag, without a CNI upgrade
    # at the same time. The module's default resolve_conflicts_on_create
    # (OVERWRITE) takes ownership of the existing aws-node objects; its env
    # was confirmed to hold only stock values, so nothing custom is lost.
    vpc-cni = {
      addon_version = "v1.22.4-eksbuild.3"
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  tags = {
    Environment = "production"
    Project     = "crypto-wallet-idp"
    ManagedBy   = "OpenTofu"
  }
}