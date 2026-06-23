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

echo -e "\n🔹 Step 6: Waiting for Vault Agent Injector to run..."
until kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg &>/dev/null; do
    echo "⌛ Waiting for Vault Webhook Configuration to be created by ArgoCD..."
    sleep 5
done

echo "⚡ Performing MutatingWebhook TLS Sync..."
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg --ignore-not-found=true

echo -e "\n🔹 Step 7: Executing Hard Refresh and triggering deployment sync..."
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