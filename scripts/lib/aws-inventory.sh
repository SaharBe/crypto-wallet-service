# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# Read-only AWS lookups shared by scripts/verify-clean.sh and
# scripts/teardown.sh. Sourced, not executed.
#
# Every inv_* function prints one resource per line as "<id>\t<detail>" and
# nothing at all when there is no match. None of them modify AWS.
#
# A failed AWS call must never read as "nothing found": callers run with
# `set -euo pipefail` plus `shopt -s inherit_errexit` (so errors inside
# $(...) abort too), and every AWS call here is a plain command or a
# variable assignment, never hidden in `< <(...)` or an `if` pipeline whose
# exit status bash would drop.
#
# What counts as "ours" (any one is enough):
#   - Project tag = crypto-wallet (Terraform default_tags, gp3 StorageClass),
#     or one of the legacy values crypto-wallet-idp / crypto-wallet-service
#     that the EKS and VPC modules used before default_tags existed. Keeping
#     the legacy values means resources leaked before this change still show up.
#   - kubernetes.io/cluster/<cluster> (EKS, EBS CSI, in-tree LB controller)
#   - ebs.csi.aws.com/cluster-name / KubernetesCluster = <cluster> (EBS CSI)
#   - cluster.k8s.amazonaws.com/name = <cluster> (VPC-CNI ENIs)
#   - eks:cluster-name = <cluster> (instances EKS launches for node groups)
#
# Deliberately NOT a generic "everything tagged Project=crypto-wallet" sweep
# through the Resource Groups Tagging API: the Terraform state bucket and lock
# table (terraform/state-backend) carry Project=crypto-wallet too and must
# survive `make down`. Each check below queries one service's own API, and
# S3/DynamoDB are never queried, so they're excluded by construction. The
# default VPC is excluded by an is-default=false filter. Resources from other
# projects in the account (an Elastic Beanstalk environment, wikijs-vpc, ...)
# carry none of these tags, so they never match.
# ─────────────────────────────────────────────────────────────────────────────

CLUSTER_NAME="${CLUSTER_NAME:-crypto-wallet-eks-cluster}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
# Never open a pager; these scripts run unattended.
export AWS_PAGER=""

PROJECT_TAG_VALUES="crypto-wallet,crypto-wallet-idp,crypto-wallet-service"
CLUSTER_TAG_KEY="kubernetes.io/cluster/${CLUSTER_NAME}"

# Matches a Project tag value or a cluster-ownership tag in "key<TAB>value"
# lines on stdin (pass already-fetched tags, never a live aws pipeline). Used for services whose describe calls can't filter by tag
# (ELB, ECR, IAM).
_tags_are_ours() {
  awk -F'\t' -v ck="$CLUSTER_TAG_KEY" -v cn="$CLUSTER_NAME" -v pv=",$PROJECT_TAG_VALUES," '
    $1 == "Project" && index(pv, "," $2 ",") { found = 1 }
    $1 == ck { found = 1 }
    $1 == "elbv2.k8s.aws/cluster" && $2 == cn { found = 1 }
    $1 == "eks:cluster-name" && $2 == cn { found = 1 }
    END { exit found ? 0 : 1 }'
}

# Non-default VPCs that belong to the project. Other checks also look inside
# these VPCs, which catches an untagged resource sitting in a project VPC.
inv_vpcs() {
  {
    aws ec2 describe-vpcs --output text \
      --filters Name=is-default,Values=false "Name=tag:Project,Values=${PROJECT_TAG_VALUES}" \
      --query "Vpcs[].[VpcId, join('', ['cidr=', CidrBlock, ' name=', (Tags[?Key=='Name'].Value | [0]) || '-'])]"
    aws ec2 describe-vpcs --output text \
      --filters Name=is-default,Values=false "Name=tag-key,Values=${CLUSTER_TAG_KEY}" \
      --query "Vpcs[].[VpcId, join('', ['cidr=', CidrBlock, ' name=', (Tags[?Key=='Name'].Value | [0]) || '-'])]"
  } | sort -u
}

_project_vpc_ids_csv() {
  inv_vpcs | cut -f1 | paste -sd, -
}

inv_ebs_volumes() {
  local q="Volumes[].[VolumeId, join('', ['state=', State, ' size=', to_string(Size), 'GiB pvc=', \
(Tags[?Key=='kubernetes.io/created-for/pvc/namespace'].Value | [0]) || '-', '/', \
(Tags[?Key=='kubernetes.io/created-for/pvc/name'].Value | [0]) || '-'])]"
  local states="Name=status,Values=creating,available,in-use,error"
  {
    aws ec2 describe-volumes --output text --filters "$states" "Name=tag:Project,Values=${PROJECT_TAG_VALUES}" --query "$q"
    aws ec2 describe-volumes --output text --filters "$states" "Name=tag-key,Values=${CLUSTER_TAG_KEY}" --query "$q"
    aws ec2 describe-volumes --output text --filters "$states" "Name=tag:ebs.csi.aws.com/cluster-name,Values=${CLUSTER_NAME}" --query "$q"
    aws ec2 describe-volumes --output text --filters "$states" "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" --query "$q"
    # Cluster-agnostic keys the CSI driver puts on every dynamically
    # provisioned volume. This account has no other EKS cluster, so a match
    # is ours; if that ever changes, a false positive here fails loudly,
    # which is the safe direction.
    aws ec2 describe-volumes --output text --filters "$states" "Name=tag-key,Values=ebs.csi.aws.com/cluster" --query "$q"
    aws ec2 describe-volumes --output text --filters "$states" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" --query "$q"
  } | sort -u
}

# State of specific volume ids. Teardown uses it to wait on exactly the
# volumes this cluster's PVs pointed at, never on volumes leaked earlier.
inv_volumes_by_id() {
  local ids_csv="$1"
  [ -n "$ids_csv" ] || return 0
  aws ec2 describe-volumes --output text --filters "Name=volume-id,Values=${ids_csv}" \
    --query "Volumes[].[VolumeId, join('', ['state=', State, ' size=', to_string(Size), 'GiB'])]"
}

inv_ec2_instances() {
  local q="Reservations[].Instances[].[InstanceId, join('', ['state=', State.Name, ' type=', InstanceType, ' vpc=', VpcId || '-'])]"
  local states="Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down"
  {
    aws ec2 describe-instances --output text --filters "$states" "Name=tag:Project,Values=${PROJECT_TAG_VALUES}" --query "$q"
    aws ec2 describe-instances --output text --filters "$states" "Name=tag-key,Values=${CLUSTER_TAG_KEY}" --query "$q"
    aws ec2 describe-instances --output text --filters "$states" "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" --query "$q"
  } | sort -u
}

inv_nat_gateways() {
  local q="NatGateways[].[NatGatewayId, join('', ['state=', State, ' vpc=', VpcId])]"
  local states="Name=state,Values=pending,available,deleting"
  local vpcs
  vpcs=$(_project_vpc_ids_csv)
  {
    aws ec2 describe-nat-gateways --output text --filter "$states" "Name=tag:Project,Values=${PROJECT_TAG_VALUES}" --query "$q"
    if [ -n "$vpcs" ]; then
      aws ec2 describe-nat-gateways --output text --filter "$states" "Name=vpc-id,Values=${vpcs}" --query "$q"
    fi
  } | sort -u
}

inv_eips() {
  local q="Addresses[].[AllocationId, join('', ['ip=', PublicIp, ' associated=', AssociationId || 'no'])]"
  {
    aws ec2 describe-addresses --output text --filters "Name=tag:Project,Values=${PROJECT_TAG_VALUES}" --query "$q"
    aws ec2 describe-addresses --output text --filters "Name=tag-key,Values=${CLUSTER_TAG_KEY}" --query "$q"
  } | sort -u
}

# ENIs inside project VPCs, plus VPC-CNI ENIs wherever they are.
inv_enis() {
  local q="NetworkInterfaces[].[NetworkInterfaceId, join('', ['status=', Status, ' type=', InterfaceType, ' vpc=', VpcId, ' desc=', Description || '-'])]"
  local vpcs
  vpcs=$(_project_vpc_ids_csv)
  {
    if [ -n "$vpcs" ]; then
      aws ec2 describe-network-interfaces --output text --filters "Name=vpc-id,Values=${vpcs}" --query "$q"
    fi
    aws ec2 describe-network-interfaces --output text --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=${CLUSTER_NAME}" --query "$q"
  } | sort -u
}

# Non-default security groups inside project VPCs, plus any SG carrying the
# cluster tag (EKS's own eks-cluster-sg-*, in-tree LB controller k8s-elb-*).
inv_security_groups() {
  local q="SecurityGroups[?GroupName!='default'].[GroupId, join('', ['name=', GroupName, ' vpc=', VpcId])]"
  local vpcs
  vpcs=$(_project_vpc_ids_csv)
  {
    if [ -n "$vpcs" ]; then
      aws ec2 describe-security-groups --output text --filters "Name=vpc-id,Values=${vpcs}" --query "$q"
    fi
    aws ec2 describe-security-groups --output text --filters "Name=tag-key,Values=${CLUSTER_TAG_KEY}" --query "$q"
  } | sort -u
}

# Security groups Kubernetes creates for LoadBalancer Services (k8s-elb-*
# from the in-tree controller, k8s-* from the AWS LB controller).
inv_k8s_lb_security_groups() {
  aws ec2 describe-security-groups --output text \
    --filters "Name=tag-key,Values=${CLUSTER_TAG_KEY}" "Name=group-name,Values=k8s-*" \
    --query "SecurityGroups[].[GroupId, join('', ['name=', GroupName, ' vpc=', VpcId])]"
}

inv_load_balancers() {
  local vpcs lbs tags name vpc dns arn
  vpcs=",$(_project_vpc_ids_csv),"
  # Classic ELBs (what a Service of type LoadBalancer gets from the in-tree
  # cloud provider). describe-load-balancers can't filter by tag, so each
  # LB outside a project VPC has its tags checked individually.
  lbs=$(aws elb describe-load-balancers --output text \
    --query 'LoadBalancerDescriptions[].[LoadBalancerName, VPCId, DNSName]')
  while IFS=$'\t' read -r name vpc dns; do
    [ -n "$name" ] || continue
    tags=""
    [[ "$vpcs" == *",$vpc,"* ]] || tags=$(aws elb describe-tags --load-balancer-names "$name" \
      --output text --query 'TagDescriptions[].Tags[].[Key, Value]')
    if [[ "$vpcs" == *",$vpc,"* ]] || _tags_are_ours <<<"$tags"; then
      printf '%s\ttype=classic vpc=%s dns=%s\n' "$name" "$vpc" "$dns"
    fi
  done <<<"$lbs"
  # ALB/NLB (AWS Load Balancer Controller, or service.beta annotations).
  lbs=$(aws elbv2 describe-load-balancers --output text \
    --query 'LoadBalancers[].[LoadBalancerArn, VpcId, DNSName]')
  while IFS=$'\t' read -r arn vpc dns; do
    [ -n "$arn" ] || continue
    tags=""
    [[ "$vpcs" == *",$vpc,"* ]] || tags=$(aws elbv2 describe-tags --resource-arns "$arn" \
      --output text --query 'TagDescriptions[].Tags[].[Key, Value]')
    if [[ "$vpcs" == *",$vpc,"* ]] || _tags_are_ours <<<"$tags"; then
      printf '%s\ttype=v2 vpc=%s dns=%s\n' "$arn" "$vpc" "$dns"
    fi
  done <<<"$lbs"
}

inv_eks_clusters() {
  local names name info status project
  names=$(aws eks list-clusters --output text --query 'clusters[]')
  for name in $names; do
    # shellcheck disable=SC2016  # `-` is a JMESPath literal, not a shell expansion
    info=$(aws eks describe-cluster --name "$name" --output text \
      --query '[cluster.status, cluster.tags.Project || `-`]')
    read -r status project <<<"$info"
    if [ "$name" = "$CLUSTER_NAME" ] || [[ ",$PROJECT_TAG_VALUES," == *",$project,"* ]]; then
      printf '%s\tstatus=%s\n' "$name" "$status"
    fi
  done
}

# Repos for every service under services/ (the set ecr.tf must declare),
# plus any other repo tagged as ours.
inv_ecr_repos() {
  local services repos tags name arn
  services=" $(find services -mindepth 2 -maxdepth 2 -name Dockerfile -printf '%h\n' | xargs -rn1 basename | tr '\n' ' ') "
  repos=$(aws ecr describe-repositories --output text --query 'repositories[].[repositoryName, repositoryArn]')
  while IFS=$'\t' read -r name arn; do
    [ -n "$name" ] || continue
    tags=""
    [[ "$services" == *" $name "* ]] || tags=$(aws ecr list-tags-for-resource --resource-arn "$arn" \
      --output text --query 'tags[].[Key, Value]')
    if [[ "$services" == *" $name "* ]] || _tags_are_ours <<<"$tags"; then
      printf '%s\t%s\n' "$name" "$arn"
    fi
  done <<<"$repos"
}

# Control-plane logs. The EKS module creates /aws/eks/<cluster>/cluster in
# Terraform, but EKS can write (and so recreate) it while the cluster is
# being deleted, after Terraform has already removed it.
inv_log_groups() {
  {
    aws logs describe-log-groups --output text --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}/" \
      --query "logGroups[].[logGroupName, join('', ['stored_bytes=', to_string(storedBytes)])]"
    aws logs describe-log-groups --output text --log-group-name-prefix "/aws/containerinsights/${CLUSTER_NAME}/" \
      --query "logGroups[].[logGroupName, join('', ['stored_bytes=', to_string(storedBytes)])]"
  } | sort -u
}

# The EKS module's secrets-encryption key. KMS can't delete a key outright:
# destroy schedules it (PendingDeletion, not billed) and removes the alias.
# Only keys still usable (Enabled/Disabled) count as leftovers.
inv_kms_keys() {
  local keys aws_managed key meta manager state desc
  aws kms list-aliases --output text --query "Aliases[?AliasName=='alias/eks/${CLUSTER_NAME}'].[AliasName, TargetKeyId]"
  keys=$(aws kms list-keys --output text --query 'Keys[].KeyId')
  # AWS-managed keys (alias/aws/*) can't be ours; skipping them saves one
  # describe-key round trip each, which dominated this script's runtime.
  aws_managed=" $(aws kms list-aliases --output text \
    --query "Aliases[?starts_with(AliasName, 'alias/aws/') && TargetKeyId].TargetKeyId") "
  for key in $keys; do
    [[ "$aws_managed" == *"$key"* ]] && continue
    meta=$(aws kms describe-key --key-id "$key" --output text \
      --query 'KeyMetadata.[KeyManager, KeyState, Description]')
    IFS=$'\t' read -r manager state desc <<<"$meta"
    if [ "$manager" = "CUSTOMER" ] && [ "$state" != "PendingDeletion" ] && [[ "$desc" == *"$CLUSTER_NAME"* ]]; then
      printf '%s\tstate=%s desc=%s\n' "$key" "$state" "$desc"
    fi
  done
}

# IAM is global (not us-east-1), but these are created by terraform/infra and
# leak with it. Role/policy names are the EKS module's name prefixes.
inv_iam() {
  local arns arn tags
  aws iam list-roles --output text \
    --query "Roles[?starts_with(RoleName, '${CLUSTER_NAME}') || starts_with(RoleName, 'app_nodes-eks-node-group')].[RoleName, join('', ['role created=', CreateDate])]"
  aws iam list-policies --scope Local --output text \
    --query "Policies[?starts_with(PolicyName, '${CLUSTER_NAME}')].[PolicyName, join('', ['policy created=', CreateDate])]"
  arns=$(aws iam list-open-id-connect-providers --output text --query 'OpenIDConnectProviderList[].Arn')
  for arn in $arns; do
    tags=$(aws iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" \
      --output text --query 'Tags[].[Key, Value]')
    if _tags_are_ours <<<"$tags"; then
      printf '%s\toidc-provider\n' "$arn"
    fi
  done
}

inv_launch_templates() {
  local q="LaunchTemplates[].[LaunchTemplateId, join('', ['name=', LaunchTemplateName])]"
  {
    aws ec2 describe-launch-templates --output text --filters "Name=tag:Project,Values=${PROJECT_TAG_VALUES}" --query "$q"
    aws ec2 describe-launch-templates --output text --filters "Name=tag-key,Values=${CLUSTER_TAG_KEY}" --query "$q"
  } | sort -u
}
