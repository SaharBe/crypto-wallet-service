#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make verify-clean: read-only check that nothing `make up` created is left
# in AWS (us-east-1, plus global IAM).
#
# Runs at the end of `make down` (scripts/teardown.sh), where a non-zero exit
# makes the teardown fail, and warn-only at the start of `make up`
# (bootstrap.sh). It also runs standalone.
#
# Why it exists: `terraform destroy` only knows what is in its state. A
# VPC + NAT GW + EIP from a 2026-07-01 apply dropped out of state during the
# move to the S3 backend, and every later destroy "succeeded" without seeing
# it; the NAT billed for months. EBS volumes from PVCs were never in any
# state at all. Checking AWS itself, by tag, is the only way to know the
# account is actually clean.
#
# Exit codes: 0 = clean, 1 = leftovers found (listed), 2 = the check itself
# could not complete (credentials, throttling, ...); a 2 is NOT a clean result.
#
# What "ours" means and what is excluded (state bucket, lock table, default
# VPC, other projects) is documented in scripts/lib/aws-inventory.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# Errors inside $(...) must abort too, or a failed AWS query would read as
# "nothing found" (bash resets errexit in command substitutions otherwise).
shopt -s inherit_errexit

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/aws-inventory.sh
. scripts/lib/aws-inventory.sh

# Any exit other than the two deliberate ones below means a check failed.
FINISHED=false
on_exit() {
  local rc=$?
  if [ "$FINISHED" != true ]; then
    echo "❌ verify-clean could not complete an AWS query (exit $rc, see the error above)." >&2
    echo "   This is NOT a clean result. Check credentials (aws sts get-caller-identity) and re-run make verify-clean." >&2
    exit 2
  fi
}
trap on_exit EXIT

if ! command -v aws >/dev/null 2>&1; then
  echo "❌ aws CLI not found." >&2
  exit 2
fi
aws sts get-caller-identity --query Account --output text >/dev/null

echo "🔎 Checking ${AWS_REGION} (and global IAM) for anything left from cluster '${CLUSTER_NAME}' / Project in {${PROJECT_TAG_VALUES}}..."
echo "   Excluded by design: the default VPC, the Terraform state S3 bucket and DynamoDB lock table."

LEFTOVERS=0
check() {
  local label="$1" fn="$2" out
  out=$("$fn")
  if [ -n "$out" ]; then
    LEFTOVERS=$((LEFTOVERS + $(wc -l <<<"$out")))
    echo ""
    echo "❌ ${label}:"
    sed 's/^/     /; s/\t/  /' <<<"$out"
  else
    printf '   ✅ %-28s none\n' "$label"
  fi
}

check "EKS clusters"              inv_eks_clusters
check "EC2 instances"             inv_ec2_instances
check "EBS volumes"               inv_ebs_volumes
check "Load balancers"            inv_load_balancers
check "NAT gateways"              inv_nat_gateways
check "Elastic IPs"               inv_eips
check "VPCs (non-default)"        inv_vpcs
check "ENIs"                      inv_enis
check "Security groups"           inv_security_groups
check "Launch templates"          inv_launch_templates
check "ECR repositories"          inv_ecr_repos
check "EKS log groups"            inv_log_groups
check "KMS keys (not scheduled)"  inv_kms_keys
check "IAM roles/policies/OIDC"   inv_iam

echo ""
if [ "$LEFTOVERS" -gt 0 ]; then
  echo "❌ verify-clean: ${LEFTOVERS} resource(s) from this project are still in AWS (listed above)."
  echo "   After a teardown: re-run 'make down' (it is idempotent). If they persist, they are outside"
  echo "   Terraform state (e.g. leaked before this check existed): inspect and delete them in the"
  echo "   AWS console/CLI, then run 'make verify-clean' again."
  FINISHED=true
  exit 1
fi
echo "✅ verify-clean: nothing from this project is left in AWS."
FINISHED=true
