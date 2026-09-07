#!/bin/bash

set -e

START_TIME=$SECONDS

echo "=================================================="
echo "🚀 Starting Enterprise IDP Bootstrap Process..."
echo "=================================================="

if [ ! -f "secrets.env" ]; then
  echo "❌ secrets.env not found. Copy secrets.env.example to secrets.env and fill in real values first."
  exit 1
fi
# shellcheck disable=SC1091
source secrets.env

# Single source of truth for the platform's Git repo URL (secrets.env).
: "${REPO_URL:?REPO_URL must be set in secrets.env — see secrets.env.example}"
if ! command -v envsubst >/dev/null 2>&1; then
  echo "❌ envsubst not found. Install the 'gettext' package (provides envsubst)."
  exit 1
fi

export TF_VAR_vault_token="$VAULT_TOKEN"
export TF_VAR_db_username="$DB_USERNAME"
export TF_VAR_db_password="$DB_PASSWORD"
export TF_VAR_github_username="$GITHUB_USERNAME"
export TF_VAR_github_pat="$GITHUB_PAT"
export TF_VAR_repo_url="$REPO_URL"

echo -e "\n🔹 Step 1: Provisioning AWS infrastructure via Terraform..."
terraform -chdir=terraform/infra init -backend-config=backend.hcl -input=false
terraform -chdir=terraform/infra apply --auto-approve

echo -e "\n🔹 Step 2: Connecting local terminal to EKS Cluster..."
aws eks update-kubeconfig --region us-east-1 --name crypto-wallet-eks-cluster

echo "🔑 Logging in to AWS ECR..."
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"

SERVICES=("order-service" "wallet-service")

for SERVICE in "${SERVICES[@]}"; do
  echo "📦 Building image for $SERVICE from ./services/$SERVICE..."
  
  docker build -t "${ECR_REGISTRY}/${SERVICE}:latest" "./services/${SERVICE}"
  
  echo "🚀 Pushing $SERVICE to ECR..."
  docker push "${ECR_REGISTRY}/${SERVICE}:latest"
done

echo "✅ Initial images are live in ECR!"

echo -e "\n🔹 Step 3: Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ApplicationSet CRDs first to prevent argocd-applicationset-controller CrashLoop (using server-side apply to avoid size limit issues)
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml

# Apply main ArgoCD manifests
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

echo "⌛ Waiting for the ArgoCD API server to become Ready..."
until kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>&1 | grep -q -v "No resources found"; do
  sleep 2
done
kubectl wait pod -n argocd -l app.kubernetes.io/name=argocd-server --for=condition=Ready --timeout=180s

echo -e "\n🔹 Setting permanent admin password for ArgoCD..."
kubectl patch secret argocd-secret -n argocd \
  -p '{"stringData": {
    "admin.password": "$2a$10$Ks7VkSbYBQYeV4UYVHqam.0ERCRe4pbn4HYFJsI/rzn.gF1J32W9a",
    "admin.passwordMtime": "2026-07-14T12:00:00Z"
  }}'

kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
echo -e "\n🔹 Getting permanent admin password for ArgoCD:"
kubectl get secret argocd-secret -n argocd -o yaml

echo -e "\n🔹 Step 4: Seeding the bootstrap-time GitHub repo credential..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: private-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: "$REPO_URL"
  username: "$GITHUB_USERNAME"
  password: "$GITHUB_PAT"
EOF

echo -e "\n🔹 Step 5: Registering the App-of-Apps..."
# root-app.yaml carries ${REPO_URL} as a placeholder — rendered here rather
# than hardcoded. It's applied imperatively (not synced by ArgoCD), so this
# is the one place it needs substituting.
envsubst '${REPO_URL}' < k8s/root-app.yaml | kubectl apply -f -

echo -e "\n🔹 Step 6: Waiting for ArgoCD to finish syncing Infrastructure apps..."

INFRA_APPS=("vault" "external-secrets" "kafka")

for app in "${INFRA_APPS[@]}"; do
  echo "⌛ Waiting for '$app' Application resource to be created by ArgoCD..."
  until kubectl get application "$app" -n argocd >/dev/null 2>&1; do
    sleep 3
  done

  echo "⌛ Waiting for '$app' to become Synced/Healthy..."
  kubectl wait application "$app" -n argocd \
    --for=jsonpath='{.status.sync.status}'=Synced \
    --timeout=300s
  kubectl wait application "$app" -n argocd \
    --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=300s
done

echo -e "\n🔹 Step 7: Configuring Vault via Terraform (auth, policy, roles, secrets)..."
echo "🔌 Port-forwarding Vault so Terraform can reach it from outside the cluster..."
kubectl port-forward svc/vault -n vault 8200:8200 > /dev/null 2>&1 &
VAULT_PF_PID=$!
trap 'kill $VAULT_PF_PID 2>/dev/null || true' EXIT

until curl -s -o /dev/null http://127.0.0.1:8200/v1/sys/health; do
  sleep 2
done

terraform -chdir=terraform/vault-config init -backend-config=backend.hcl -input=false
terraform -chdir=terraform/vault-config apply --auto-approve
echo "✅ Vault configured successfully via Terraform!"

kill "$VAULT_PF_PID" 2>/dev/null || true
trap - EXIT

echo -e "\n🔹 Step 8: Waiting for crypto-wallet-app and monitoring-stack to consume secrets and become Healthy..."
# monitoring-stack syncs at wave "1" (see k8s/apps/monitoring-app.yaml), so
# root-app only creates its Application resource once wave 0 — which
# includes crypto-wallet-app — is itself Synced/Healthy. crypto-wallet-app's
# own health depends on the terraform apply above too, so on a clean
# bootstrap neither Application is guaranteed to exist by the time this step
# starts. Wait for each to actually be created before `kubectl wait`-ing on
# it, same guard Step 6 uses for INFRA_APPS — without it, a fresh cluster
# hits "applications.argoproj.io \"monitoring-stack\" not found".
for app in "crypto-wallet-app" "monitoring-stack"; do
  echo "⌛ Waiting for '$app' Application resource to be created by ArgoCD..."
  # Bounded, unlike Step 6's equivalent loop: this Application only appears
  # once wave 0 fully succeeds, which includes apps unrelated to this fix
  # (e.g. kyverno) that could stall for reasons of their own. Fail loudly
  # after 5 minutes instead of hanging bootstrap.sh forever.
  WAIT_ELAPSED=0
  until kubectl get application "$app" -n argocd >/dev/null 2>&1; do
    if [ "$WAIT_ELAPSED" -ge 300 ]; then
      echo "❌ Timed out after 300s waiting for Application '$app' to be created by ArgoCD."
      echo "   Check 'kubectl get applications -n argocd' — a wave-0 app may be stuck failing"
      echo "   and blocking wave 1 (root-application won't retry a failed sync on its own)."
      exit 1
    fi
    sleep 3
    WAIT_ELAPSED=$((WAIT_ELAPSED + 3))
  done

  # Restart the app's Deployments once its Application object exists, so
  # pods that came up before ESO synced their secret pick it up now rather
  # than waiting on kubelet's own retry timing. Namespace/deployment name
  # may still not exist yet even after the Application resource does (its
  # own sync could still be in flight), hence || true.
  if [ "$app" = "crypto-wallet-app" ]; then
    kubectl rollout restart deployment -n crypto-wallet-app --all 2>/dev/null || true
  else
    kubectl rollout restart deployment -n monitoring monitoring-stack-grafana 2>/dev/null || true
  fi

  echo "⌛ Waiting for '$app' to become Synced/Healthy..."
  kubectl wait application "$app" -n argocd \
    --for=jsonpath='{.status.sync.status}'=Synced \
    --timeout=300s
  kubectl wait application "$app" -n argocd \
    --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=300s
done

echo -e "\n=================================================="
echo "✅ Bootstrap script completed successfully!"
echo "=================================================="

END_TIME=$SECONDS
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS_REM=$((DURATION % 60))

echo -e "\n⏱️  Total Execution Time: ${MINUTES}m ${SECONDS_REM}s"