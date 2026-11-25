#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-ecr-repos.sh [--in-aws] <service>...
#
# Fails unless every named service has its ECR repository declared in
# terraform/infra/ecr.tf. With --in-aws, also fails unless the repository
# actually exists (i.e. `terraform apply` has run).
#
# Why fail instead of creating: bootstrap.sh and `make build` used to run
# `aws ecr create-repository` when a repo was missing. A repo created that
# way lives outside Terraform state, so `make down` never destroyed it, and
# the next `terraform apply` of the same name failed with
# RepositoryAlreadyExistsException. Terraform is the only place repos are
# created; this check makes forgetting one loud instead of silent.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."
ECR_TF="terraform/infra/ecr.tf"
AWS_REGION="${AWS_REGION:-us-east-1}"

IN_AWS=false
if [ "${1:-}" = "--in-aws" ]; then
  IN_AWS=true
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "usage: $0 [--in-aws] <service>..." >&2
  exit 2
fi

missing=0
for svc in "$@"; do
  if ! grep -Eq "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"${svc}\"[[:space:]]*$" "$ECR_TF"; then
    echo "❌ ECR repo '${svc}' not in ${ECR_TF}."
    echo "   Add an aws_ecr_repository for it there (copy an existing block, keep force_delete = true)"
    echo "   and run 'terraform -chdir=terraform/infra apply'. Repos are never created outside Terraform."
    missing=1
    continue
  fi
  if [ "$IN_AWS" = true ]; then
    if ! err=$(aws ecr describe-repositories --repository-names "$svc" --region "$AWS_REGION" 2>&1 >/dev/null); then
      if grep -q RepositoryNotFoundException <<<"$err"; then
        echo "❌ ECR repo '${svc}' is declared in ${ECR_TF} but doesn't exist in ${AWS_REGION}."
        echo "   Run 'terraform -chdir=terraform/infra apply' (or 'make up') first."
      else
        echo "❌ Could not check ECR repo '${svc}': ${err}"
      fi
      missing=1
    fi
  fi
done
exit "$missing"
