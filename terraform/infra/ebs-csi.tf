# Postgres and Kafka currently run with no PersistentVolumeClaim at all —
# their data lives in the pod's ephemeral container filesystem. Fixing that
# needs a working block-storage provisioner: this cluster runs EKS 1.31,
# where Kubernetes' legacy in-tree `kubernetes.io/aws-ebs` provisioner
# (which the cluster's existing, untracked `gp2` StorageClass still points
# at) was removed outright back in 1.23 — confirmed live via
# `kubectl get csidrivers` showing no `ebs.csi.aws.com` and no
# ebs-csi-controller pod in kube-system. A PVC against that StorageClass
# would sit Pending forever.
#
# module.eks defaults `enable_irsa = true` (unchanged here), so the IAM OIDC
# provider for this cluster already exists (confirmed live via
# `aws iam list-open-id-connect-providers`) — this file only adds the IRSA
# role the EBS CSI driver's ServiceAccount needs to call the EC2/EBS API,
# and registers the driver itself as an EKS addon on module.eks.

data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${local.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json

  tags = {
    Environment = "production"
    Project     = "crypto-wallet-idp"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
