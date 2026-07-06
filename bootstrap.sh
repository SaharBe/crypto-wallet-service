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
export TF_VAR_vault_token="$VAULT_TOKEN"
export TF_VAR_db_username="$DB_USERNAME"
export TF_VAR_db_password="$DB_PASSWORD"
export TF_VAR_github_username="$GITHUB_USERNAME"
export TF_VAR_github_pat="$GITHUB_PAT"

echo -e "\n🔹 Step 1: Provisioning AWS infrastructure via Terraform..."
terraform -chdir=terraform/infra init -backend-config=backend.hcl -input=false
terraform -chdir=terraform/infra apply --auto-approve

echo -e "\n🔹 Step 2: Connecting local terminal to EKS Cluster..."
aws eks update-kubeconfig --region us-east-1 --name crypto-wallet-eks-cluster

echo -e "\n🔹 Step 3: Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

echo "⌛ Waiting for the ArgoCD API server to become Ready..."
until kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>&1 | grep -q -v "No resources found"; do
  sleep 2
done
kubectl wait pod -n argocd -l app.kubernetes.io/name=argocd-server --for=condition=Ready --timeout=180s

echo -e "\n🔹 Step 4: Seeding the bootstrap-time GitHub repo credential..."
# ArgoCD needs to read this private repo before it can sync anything from it —
# including k8s/apps/argocd-repo-secret.yaml, which is what lets ESO/Vault take
# over managing this same Secret afterwards. This bootstrap copy is never
# written to disk as a manifest and never committed.
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
  url: "https://github.com/SaharBe/crypto-wallet-service.git"
  username: "$GITHUB_USERNAME"
  password: "$GITHUB_PAT"
EOF

echo -e "\n🔹 Step 5: Registering the App-of-Apps..."
kubectl apply -f k8s/root-app.yaml

echo -e "\n🔹 Step 6: Configuring Vault via Terraform (auth, policy, roles, secrets)..."
echo "⌛ Waiting for ArgoCD to deploy the Vault pod..."
until kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server 2>&1 | grep -q -v "No resources found"; do
  sleep 2
done
kubectl wait pod -n vault \
  -l app.kubernetes.io/name=vault,component=server \
  --for=condition=Ready \
  --timeout=180s

echo "🔌 Port-forwarding Vault so Terraform can reach it from outside the cluster..."
kubectl port-forward svc/vault -n vault 8200:8200 > /dev/null 2>&1 &
VAULT_PF_PID=$!
trap 'kill $VAULT_PF_PID 2>/dev/null || true' EXIT
until curl -s -o /dev/null http://127.0.0.1:8200/v1/sys/health; do
  sleep 2
done

terraform -chdir=terraform/vault-config init -backend-config=backend.hcl -input=false
terraform -chdir=terraform/vault-config apply --auto-approve
echo "✅ Vault configured"

kill "$VAULT_PF_PID" 2>/dev/null || true
trap - EXIT

echo -e "\n🔹 Step 7: Waiting for ArgoCD to finish syncing all applications..."
for app in vault external-secrets crypto-wallet-app; do
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
