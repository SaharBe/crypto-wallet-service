#!/bin/bash

set -e

START_TIME=$SECONDS

echo "=================================================="
echo "🚀 Starting Enterprise IDP Bootstrap Process..."
echo "=================================================="

echo -e "\n🔹 Step 1: Initializing Cloud Infrastructure via Terraform..."
cd terraform
terraform apply --auto-approve
cd ..

echo -e "\n🔹 Step 2: Connecting local terminal to EKS Cluster..."
aws eks update-kubeconfig --region us-east-1 --name crypto-wallet-eks-cluster

# 3. ArgoCD Installation
echo -e "\n🔹 Step 3: Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

echo "🔌 Starting ArgoCD port-forward in the background..."
(
    until kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1; do
        sleep 5
    done
) &
echo "🚀 Port-forward process initiated (will become available automatically once ArgoCD service is up)"

echo -e "\n🔹 Step 4: Applying GitHub Repository Secret for ArgoCD..."
if [ -f "k8s/repo-secret.yaml" ]; then
    kubectl apply -f k8s/repo-secret.yaml
else
    echo "⚠️ Warning: k8s/repo-secret.yaml not found. Skipping... (Make sure to apply it manually if needed)"
fi

echo -e "\n🔹 Step 5: Registering Applications (Vault & Crypto-App) in ArgoCD..."
kubectl apply -f k8s/apps/vault.yaml
kubectl apply -f k8s/apps/crypto-app.yaml

kubectl patch application crypto-wallet-app -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'

echo -e "\n🔹 Step 6: Initializing Vault (auth, policy, role, secrets)..."

echo "⌛ Waiting for Vault pod to become Ready..."
kubectl wait pod -n vault \
  -l app.kubernetes.io/name=vault,component=server \
  --for=condition=Ready \
  --timeout=180s

VAULT_POD=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server \
  -o jsonpath='{.items[0].metadata.name}')

echo "🔑 Configuring Kubernetes auth method inside Vault pod ($VAULT_POD)..."

# Enable Kubernetes auth (idempotent)
kubectl exec -n vault "$VAULT_POD" -- \
  env VAULT_TOKEN=root vault auth enable kubernetes 2>/dev/null || true

# Configure Kubernetes auth using the in-cluster API server — NOT localhost
kubectl exec -n vault "$VAULT_POD" -- \
  env VAULT_TOKEN=root vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443

# Create policy granting read access to the KV v2 secret path
kubectl exec -n vault -i "$VAULT_POD" -- \
  env VAULT_TOKEN=root vault policy write crypto-app-policy - <<'VAULT_POLICY'
path "secret/data/crypto-db" {
  capabilities = ["read"]
}
VAULT_POLICY

# Create role binding crypto-sa in namespace default
kubectl exec -n vault "$VAULT_POD" -- \
  env VAULT_TOKEN=root vault write auth/kubernetes/role/crypto-app-role \
  bound_service_account_names=crypto-sa \
  bound_service_account_namespaces=default \
  policies=crypto-app-policy \
  ttl=24h

# Enable KV v2 secrets engine at path "secret" (idempotent)
kubectl exec -n vault "$VAULT_POD" -- \
  env VAULT_TOKEN=root vault secrets enable -path=secret kv-v2 2>/dev/null || true

# Write the initial database secret
kubectl exec -n vault "$VAULT_POD" -- \
  env VAULT_TOKEN=root vault kv put secret/crypto-db \
  username=myuser \
  password=mypassword

echo "✅ Vault fully initialized"

echo -e "\n🔹 Step 8: Waiting for Vault Agent Injector to run..."
until kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg &>/dev/null; do
    echo "⌛ Waiting for Vault Webhook Configuration to be created by ArgoCD..."
    sleep 5
done

echo "⚡ Performing MutatingWebhook TLS Sync..."
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg --ignore-not-found=true

echo "⌛ Waiting for ArgoCD to recreate the MutatingWebhookConfiguration..."
until kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg &>/dev/null; do
    sleep 5
done

echo "♻️  Restarting Vault injector to force immediate caBundle rotation..."
kubectl rollout restart deployment/vault-agent-injector -n vault
kubectl rollout status deployment/vault-agent-injector -n vault --timeout=120s

echo "⌛ Waiting for Vault injector to populate caBundle in the webhook..."
until kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q '[A-Za-z0-9+/=]'; do
    echo "  caBundle still empty, waiting..."
    sleep 5
done
echo "✅ caBundle is populated — webhook is ready to inject"

echo -e "\n🔹 Step 9: Executing Hard Refresh and triggering deployment sync..."
kubectl annotate application crypto-wallet-app -n argocd argocd.argoproj.io/refresh=hard --overwrite

kubectl delete pod -l app=node-app --ignore-not-found=true

echo -e "\n=================================================="
echo "✅ Bootstrap script completed successfully!"
echo "=================================================="

END_TIME=$SECONDS
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS_REM=$((DURATION % 60))

echo -e "\n⏱️  Total Execution Time: ${MINUTES}m ${SECONDS_REM}s"