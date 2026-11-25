#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make down: tear down everything `make up` created, then prove it with
# `make verify-clean`. Only the Terraform state bucket and lock table remain.
#
# Why not just `terraform destroy`: Kubernetes creates AWS resources that
# Terraform never sees. PVCs get EBS volumes from the EBS CSI driver, and
# Services of type LoadBalancer get ELBs plus security groups. Those are only
# deleted when the controller that made them is still running to do it. A
# bare destroy removed the nodes and the CSI add-on while PVCs were still
# bound, so every up/down cycle leaked Postgres' 5Gi and Kafka's 8Gi volume.
# The order below runs every in-cluster cleanup while the cluster can still
# act on it, and checks each one against the AWS API, not Kubernetes' word:
#
#   1. Find the cluster. If it's already gone (or half-deleted by an earlier
#      run), skip the Kubernetes steps; init/destroy/verify still run.
#   2. Delete the ArgoCD ApplicationSet and Applications (cascading, via
#      resources-finalizer). Otherwise selfHeal recreates whatever we delete.
#   3. Delete LoadBalancer Services and Ingresses; wait until the AWS load
#      balancers and their security groups are gone.
#   4. Delete the PVC-mounting workloads and every PVC; wait until the EBS
#      volumes behind them are deleted in AWS.
#   5. terraform destroy, in two phases: EKS first, then sweep ENIs/SGs that
#      Kubernetes or EKS left in the VPC (the usual DependencyViolation on
#      subnet/VPC delete), then everything else.
#   6. verify-clean. If anything tagged for this project survives, fail.
#
# Idempotent: every step tolerates "already gone", so after a failure, fix
# the cause and re-run `make down`. Every wait is bounded (override the
# *_TIMEOUT variables below) and ends in an error that says what's stuck.
# Never deletes anything outside this cluster / Terraform state; what's
# outside state is left for verify-clean to report.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# Errors inside $(...) must abort too; without this bash silently ignores a
# failed AWS/kubectl call in a command substitution and carries on.
shopt -s inherit_errexit

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/aws-inventory.sh
. scripts/lib/aws-inventory.sh

TF_INFRA_DIR="${TF_INFRA_DIR:-terraform/infra}"
ARGOCD_DELETE_TIMEOUT="${ARGOCD_DELETE_TIMEOUT:-600}"
LB_DELETE_TIMEOUT="${LB_DELETE_TIMEOUT:-600}"
PVC_DELETE_TIMEOUT="${PVC_DELETE_TIMEOUT:-300}"
EBS_DELETE_TIMEOUT="${EBS_DELETE_TIMEOUT:-600}"
ENI_RELEASE_TIMEOUT="${ENI_RELEASE_TIMEOUT:-900}"

START_TIME=$SECONDS
STEP="preflight"

# A throwaway kubeconfig: kubectl can only ever talk to this cluster, never
# whatever context ~/.kube/config happens to point at, and the operator's
# kubeconfig isn't modified.
WORKDIR=$(mktemp -d)
export KUBECONFIG="$WORKDIR/kubeconfig"

on_exit() {
  local rc=$?
  rm -rf "$WORKDIR"
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=================================================="
    echo "❌ make down FAILED during: ${STEP} (exit ${rc})"
    echo "   The account may still hold billable resources. Fix the cause above"
    echo "   and re-run 'make down'; every step is safe to repeat."
    echo "=================================================="
  fi
}
trap on_exit EXIT

# wait_until_empty <timeout_s> <description> <on_timeout> <command...>
# Polls until the command prints nothing, reporting progress every ~30s.
# On timeout it prints what's still there, then either exits 1
# (on_timeout=fail) or runs the named function and returns.
#
# Always called as a plain statement, never inside `if`/`||`: bash turns
# errexit off for a whole function called in a condition, so a failing
# kubectl/aws call in the polled command would print nothing and pass for
# "all gone". Called plainly, such a failure aborts the teardown instead.
wait_until_empty() {
  local timeout="$1" what="$2" on_timeout="$3" elapsed=0 out
  shift 3
  while true; do
    out=$("$@")
    if [ -z "$out" ]; then
      echo "✅ ${what}: none left (${elapsed}s)."
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "❌ Timed out after ${timeout}s waiting for ${what} to be gone. Still present:"
      sed 's/^/     /; s/\t/  /' <<<"$out"
      [ "$on_timeout" = fail ] && exit 1
      "$on_timeout"
      return 0
    fi
    if [ $((elapsed % 30)) -eq 0 ]; then
      echo "   ...${what}: $(wc -l <<<"$out") remaining (${elapsed}s/${timeout}s)"
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
}

echo "=================================================="
echo "🧨 Tearing down crypto-wallet (cluster ${CLUSTER_NAME}, ${AWS_REGION})"
echo "=================================================="

for cmd in aws terraform kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ $cmd not found; make down needs aws, terraform, kubectl and jq."
    exit 1
  fi
done
if [ ! -f "${TF_INFRA_DIR}/backend.hcl" ]; then
  echo "❌ ${TF_INFRA_DIR}/backend.hcl not found. Copy backend.hcl.example and fill it in"
  echo "   from 'terraform -chdir=terraform/state-backend output'; without it destroy can't find the state."
  exit 1
fi
aws sts get-caller-identity --query Arn --output text >/dev/null

# ── Step 1 ──────────────────────────────────────────────────────────────────
STEP="Step 1 (locate cluster)"
echo -e "\n🔹 Step 1: Locating EKS cluster '${CLUSTER_NAME}'..."
if ! DESCRIBE=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.status --output text 2>&1); then
  if grep -q ResourceNotFoundException <<<"$DESCRIBE"; then
    CLUSTER_STATUS="ABSENT"
  else
    echo "❌ Could not query the cluster: $DESCRIBE"
    exit 1
  fi
else
  CLUSTER_STATUS="$DESCRIBE"
fi

K8S=false
case "$CLUSTER_STATUS" in
  ACTIVE | UPDATING)
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG" >/dev/null
    if kubectl get --raw=/readyz --request-timeout=20s >/dev/null 2>&1; then
      K8S=true
      echo "✅ Cluster is ${CLUSTER_STATUS} and its API is reachable."
    elif [ "${TEARDOWN_SKIP_K8S:-}" = "1" ]; then
      echo "⚠️  Cluster API unreachable; TEARDOWN_SKIP_K8S=1 set, skipping in-cluster cleanup."
      echo "   PVC volumes and LBs will likely leak; verify-clean at the end will list them."
    else
      echo "❌ Cluster is ${CLUSTER_STATUS} but its API isn't reachable (kubectl get --raw=/readyz failed)."
      echo "   Skipping in-cluster cleanup would leak PVC volumes and load balancers."
      echo "   Check your AWS identity has cluster access, or re-run with TEARDOWN_SKIP_K8S=1 to"
      echo "   accept the leak (verify-clean at the end will list what's left)."
      exit 1
    fi
    ;;
  ABSENT)
    echo "ℹ️  Cluster doesn't exist; skipping in-cluster cleanup (Steps 2-4)."
    ;;
  *)
    echo "⚠️  Cluster status is ${CLUSTER_STATUS}; skipping in-cluster cleanup (Steps 2-4)."
    echo "   (DELETING usually means an earlier 'make down' got as far as Terraform.)"
    ;;
esac

if [ "$K8S" = true ]; then
  # Captured up front, before anything is deleted, so the AWS-side wait in
  # Step 4 covers volumes whose PV disappears during Step 2's cascade too.
  # Only these ids are waited on: volumes leaked by earlier runs are not this
  # cluster's to delete, and verify-clean reports them instead.
  PV_JSON=$(kubectl get pv -o json)
  VOLUME_IDS=$(jq -r '.items[]
    | (.spec.csi | select(.driver == "ebs.csi.aws.com") | .volumeHandle),
      (.spec.awsElasticBlockStore.volumeID // empty | sub("^aws://[^/]*/"; ""))' <<<"$PV_JSON" | sort -u | paste -sd, -)
  echo "ℹ️  EBS volumes backing this cluster's PVs: ${VOLUME_IDS:-none}"

  # ── Step 2 ────────────────────────────────────────────────────────────────
  STEP="Step 2 (ArgoCD)"
  echo -e "\n🔹 Step 2: Deleting ArgoCD Applications so selfHeal can't recreate what we delete next..."
  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    # The ApplicationSet goes first: its controller re-renders generated
    # Applications from the template, so patching auto-sync off on them
    # wouldn't stick. Deleting it, root-application and then every remaining
    # Application lets each one's resources-finalizer cascade-delete what it
    # deployed, and nothing is left to sync it back.
    if kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1; then
      kubectl delete applicationsets.argoproj.io --all -n argocd --wait=false
    fi
    kubectl delete application root-application -n argocd --wait=false --ignore-not-found
    kubectl delete applications.argoproj.io --all -n argocd --wait=false

    argocd_remaining() {
      kubectl get applications.argoproj.io -n argocd -o name
      if kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1; then
        kubectl get applicationsets.argoproj.io -n argocd -o name
      fi
    }
    # A finalizer that never completes (a resource stuck terminating, a
    # webhook whose backend is already deleted) would block make down
    # forever. Stripping it unblocks teardown but means ArgoCD stops
    # cleaning up what that app deployed, which is exactly how AWS
    # resources get orphaned. Steps 3-4 and verify-clean check AWS
    # directly, so a leak here still fails make down; it can't pass quietly.
    strip_argocd_finalizers() {
      echo ""
      echo "⚠️  ⚠️  ⚠️  WARNING ⚠️  ⚠️  ⚠️"
      echo "⚠️  ArgoCD cascade deletion did not finish within ${ARGOCD_DELETE_TIMEOUT}s."
      echo "⚠️  STRIPPING FINALIZERS from the Applications below. Anything they still managed"
      echo "⚠️  will NOT be cleaned up by ArgoCD and may be orphaned. Teardown continues and"
      echo "⚠️  relies on the AWS-side checks (Steps 3-4, verify-clean) as the source of truth."
      kubectl get applications.argoproj.io -n argocd \
        -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase' || true
      local objs obj
      objs=$(argocd_remaining)
      for obj in $objs; do
        echo "⚠️  removing finalizers: ${obj}"
        # Tolerate "already gone": it may finish on its own between list and patch.
        kubectl patch "$obj" -n argocd --type merge -p '{"metadata":{"finalizers":null}}' || true
      done
      echo "⚠️  ⚠️  ⚠️  END WARNING ⚠️  ⚠️  ⚠️"
      wait_until_empty 60 "ArgoCD Applications (after finalizer removal)" fail argocd_remaining
    }
    wait_until_empty "$ARGOCD_DELETE_TIMEOUT" "ArgoCD Applications" strip_argocd_finalizers argocd_remaining
  else
    echo "ℹ️  ArgoCD CRDs not installed; nothing to stop."
  fi

  # ── Step 3 ────────────────────────────────────────────────────────────────
  STEP="Step 3 (load balancers)"
  echo -e "\n🔹 Step 3: Deleting LoadBalancer Services and Ingresses..."
  # ingress-nginx runs as ClusterIP and no AWS LB controller is installed,
  # so this normally finds nothing; it's here so switching either on can't
  # bring back a leak (an ELB keeps the VPC from being deleted, too).
  lb_services() {
    kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer")
      | "\(.metadata.namespace)/\(.metadata.name)"'
  }
  for svc in $(lb_services); do
    echo "   deleting Service ${svc}"
    kubectl delete svc -n "${svc%%/*}" "${svc#*/}" --wait=false --ignore-not-found
  done
  kubectl delete ingress --all -A --wait=false
  k8s_lb_objects() {
    lb_services
    kubectl get ingress -A -o name
  }
  wait_until_empty "$LB_DELETE_TIMEOUT" "LoadBalancer Services/Ingresses in Kubernetes" fail k8s_lb_objects
  # Kubernetes forgetting the Service doesn't mean AWS deleted the ELB.
  wait_until_empty "$LB_DELETE_TIMEOUT" "AWS load balancers for this cluster" fail inv_load_balancers
  wait_until_empty "$LB_DELETE_TIMEOUT" "AWS load balancer security groups (k8s-*)" fail inv_k8s_lb_security_groups

  # ── Step 4 ────────────────────────────────────────────────────────────────
  STEP="Step 4 (PVCs / EBS volumes)"
  echo -e "\n🔹 Step 4: Deleting PVCs and waiting for their EBS volumes to be deleted in AWS..."
  # Retain would keep the EBS volume after the PVC is gone, by design. make
  # down's contract is that nothing survives, so flip any such PV to Delete.
  for pv in $(jq -r '.items[] | select(.spec.persistentVolumeReclaimPolicy == "Retain") | .metadata.name' <<<"$PV_JSON"); do
    echo "   PV ${pv} has reclaimPolicy Retain; switching to Delete so its volume goes too"
    kubectl patch pv "$pv" --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' || true
  done
  # A PVC stays Terminating while any Pod mounts it (pvc-protection), and a
  # StatefulSet would recreate its Pod. Kafka's PVC comes from a
  # volumeClaimTemplate, which ArgoCD doesn't track and StatefulSets never
  # delete, so Step 2's cascade leaves it behind.
  PVC_WORKLOADS=$(kubectl get statefulsets,deployments -A -o json | jq -r '.items[]
    | select(((.spec.volumeClaimTemplates // []) | length > 0)
             or ([.spec.template.spec.volumes[]? | select(.persistentVolumeClaim)] | length > 0))
    | "\(.metadata.namespace) \(.kind | ascii_downcase) \(.metadata.name)"')
  while read -r ns kind name; do
    [ -n "$ns" ] || continue
    echo "   deleting ${kind} ${ns}/${name} (mounts a PVC)"
    kubectl delete "$kind" -n "$ns" "$name" --wait=false --ignore-not-found
  done <<<"$PVC_WORKLOADS"
  kubectl delete pvc --all -A --wait=false
  PVC_PODS=$(kubectl get pods -A -o json | jq -r '.items[]
    | select([.spec.volumes[]? | select(.persistentVolumeClaim)] | length > 0)
    | "\(.metadata.namespace) \(.metadata.name)"')
  while read -r ns name; do
    [ -n "$ns" ] || continue
    kubectl delete pod -n "$ns" "$name" --wait=false --ignore-not-found
  done <<<"$PVC_PODS"

  pvcs_and_pvs() {
    kubectl get pvc -A -o name
    kubectl get pv -o json | jq -r '.items[] | select(.spec.csi.driver == "ebs.csi.aws.com") | .metadata.name'
  }
  pvc_timeout_help() {
    echo "   Pods still mounting a PVC:"
    kubectl get pods -A -o json | jq -r '.items[] | select([.spec.volumes[]? | select(.persistentVolumeClaim)] | length > 0)
      | "     \(.metadata.namespace)/\(.metadata.name) \(.status.phase)"' || true
    echo "   A PV stuck Released/Failed usually means the EBS CSI controller can't run or reach AWS:"
    echo "   kubectl -n kube-system get pods -l app=ebs-csi-controller; kubectl get events -A | grep -i volume"
    exit 1
  }
  wait_until_empty "$PVC_DELETE_TIMEOUT" "PVCs/PVs in Kubernetes" pvc_timeout_help pvcs_and_pvs
  # The PV object going away is Kubernetes' claim; the AWS API is the proof.
  ebs_remaining() { inv_volumes_by_id "$VOLUME_IDS"; }
  ebs_timeout_help() {
    echo "   Check 'kubectl -n kube-system logs -l app=ebs-csi-controller -c csi-provisioner'."
    exit 1
  }
  wait_until_empty "$EBS_DELETE_TIMEOUT" "EBS volumes of this cluster's PVs" ebs_timeout_help ebs_remaining
fi

# ── Step 5 ──────────────────────────────────────────────────────────────────
STEP="Step 5 (terraform destroy)"
echo -e "\n🔹 Step 5: terraform destroy (${TF_INFRA_DIR})..."
# init every time: make down may run from a fresh clone or a stale
# .terraform, and destroying against the wrong (or local) state is how a
# whole VPC once went missing from Terraform's view.
terraform -chdir="$TF_INFRA_DIR" init -backend-config=backend.hcl -input=false

# A backend with no state object yet (never applied) makes `state list` exit
# 1 with "No state file was found!"; that's an empty state, not an error.
if ! TF_STATE=$(terraform -chdir="$TF_INFRA_DIR" state list 2>&1); then
  if grep -q "No state file was found" <<<"$TF_STATE"; then
    TF_STATE=""
  else
    echo "$TF_STATE"
    exit 1
  fi
fi
VPC_ID=""
if grep -qx 'module.vpc.aws_vpc.this\[0\]' <<<"$TF_STATE"; then
  VPC_ID=$(terraform -chdir="$TF_INFRA_DIR" state show -no-color 'module.vpc.aws_vpc.this[0]' \
    | awk '$1 == "id" { gsub(/"/, "", $3); print $3; exit }')
fi

# Phase 1: EKS (cluster, node group, add-ons, IRSA) on its own, so the
# instances and the EKS control plane are gone before anything touches the VPC.
if grep -q '^module\.eks\.' <<<"$TF_STATE"; then
  echo "   Phase 1/3: destroying EKS first..."
  terraform -chdir="$TF_INFRA_DIR" destroy -auto-approve -input=false -target=module.eks
else
  echo "   Phase 1/3: EKS not in state (already destroyed); skipping."
fi

# Phase 2: release the VPC. Subnet/VPC deletion fails with DependencyViolation
# while ENIs or SGs Terraform doesn't know about are still there. EKS's own
# control-plane ENIs ("Amazon EKS <cluster>") are released asynchronously a
# few minutes after the cluster is deleted; VPC-CNI ENIs ("aws-K8S-*") can be
# left detached if aws-node didn't get to clean up; and EKS's cluster SG
# (eks-cluster-sg-*) or an LB controller SG (k8s-*) can linger. Only the VPC
# in *this* Terraform state is touched, and only those name patterns.
if [ -n "$VPC_ID" ]; then
  echo "   Phase 2/3: releasing Kubernetes/EKS-created ENIs and SGs in ${VPC_ID}..."
  eks_busy_enis() {
    aws ec2 describe-network-interfaces --output text \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "NetworkInterfaces[?starts_with(Description, 'Amazon EKS') || (starts_with(Description, 'aws-K8S-') && Status=='in-use')].[NetworkInterfaceId, join('', ['status=', Status, ' desc=', Description])]"
  }
  wait_until_empty "$ENI_RELEASE_TIMEOUT" "EKS/VPC-CNI ENIs still attached in ${VPC_ID}" fail eks_busy_enis
  LEAKED_ENIS=$(aws ec2 describe-network-interfaces --output text \
    --filters "Name=vpc-id,Values=${VPC_ID}" Name=status,Values=available \
    --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-')].NetworkInterfaceId")
  for eni in $LEAKED_ENIS; do
    echo "   deleting leaked VPC-CNI ENI ${eni}"
    aws ec2 delete-network-interface --network-interface-id "$eni"
  done
  LEAKED_SGS=$(aws ec2 describe-security-groups --output text \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=${CLUSTER_TAG_KEY}" \
    --query "SecurityGroups[?starts_with(GroupName, 'eks-cluster-sg-${CLUSTER_NAME}-') || starts_with(GroupName, 'k8s-')].GroupId")
  for sg in $LEAKED_SGS; do
    echo "   deleting leftover Kubernetes/EKS security group ${sg}"
    # Not fatal here: if another SG still references it, the full destroy
    # below fails on the VPC with the real error and make down stops there.
    aws ec2 delete-security-group --group-id "$sg" || echo "   ⚠️  could not delete ${sg} yet (see above)"
  done
else
  echo "   Phase 2/3: no VPC in state; skipping ENI/SG sweep."
fi

echo "   Phase 3/3: destroying everything else (VPC, NAT, ECR, ...)..."
terraform -chdir="$TF_INFRA_DIR" destroy -auto-approve -input=false

# ── Step 6 ──────────────────────────────────────────────────────────────────
STEP="Step 6 (verify-clean)"
echo -e "\n🔹 Step 6: Verifying nothing is left in AWS..."
./scripts/verify-clean.sh

DURATION=$((SECONDS - START_TIME))
echo -e "\n=================================================="
echo "✅ make down complete: AWS is clean (state bucket and lock table kept)."
echo "⏱️  Total time: $((DURATION / 60))m $((DURATION % 60))s"
echo "=================================================="
