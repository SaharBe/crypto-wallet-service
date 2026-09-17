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
: "${ARGOCD_ADMIN_PASSWORD:?ARGOCD_ADMIN_PASSWORD must be set in secrets.env — see secrets.env.example}"
if ! command -v envsubst >/dev/null 2>&1; then
  echo "❌ envsubst not found. Install the 'gettext' package (provides envsubst)."
  exit 1
fi
if ! command -v argocd >/dev/null 2>&1; then
  echo "❌ argocd CLI not found. Install it (https://argo-cd.readthedocs.io/en/stable/cli_installation/) —"
  echo "   Step 3 uses it to hash ARGOCD_ADMIN_PASSWORD and to verify the admin login actually works."
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

SERVICES=("order-service" "wallet-service" "frontend")

for SERVICE in "${SERVICES[@]}"; do
  echo "📦 Building image for $SERVICE from ./services/$SERVICE..."

  # CI's update-manifests job (.github/workflows/ci.yml) pins each Deployment
  # to an immutable :<commit-sha> tag, not :latest — so if ECR ever comes up
  # empty against a repo whose manifests are already pinned (a fresh
  # terraform apply, a wiped registry, ...), pushing only :latest here left
  # the actually-referenced tag 404ing on pull (confirmed live: ImagePullBack-
  # Off, "not found", on a `make up` run after exactly that happened).
  # Build against whatever tag the manifest currently asks for, so this
  # step always leaves ECR holding the exact image about to be deployed,
  # regardless of whether CI has pinned it yet. Falls back to "latest" if
  # the manifest can't be parsed, matching the old unconditional behavior.
  MANIFEST="k8s/components/${SERVICE}.yaml"
  TAG=$(sed -n "s#.*/${SERVICE}:\([^[:space:]\"']*\).*#\1#p" "$MANIFEST" | head -1)
  TAG="${TAG:-latest}"

  docker build -t "${ECR_REGISTRY}/${SERVICE}:latest" "./services/${SERVICE}"
  [ "$TAG" != "latest" ] && docker tag "${ECR_REGISTRY}/${SERVICE}:latest" "${ECR_REGISTRY}/${SERVICE}:${TAG}"

  # Terraform (terraform/infra/ecr.tf) is the source of truth for these repos,
  # but a service added between infra applies would 404 on push — create on miss.
  echo "🔎 Ensuring ECR repository '$SERVICE' exists..."
  aws ecr describe-repositories --repository-names "$SERVICE" --region us-east-1 >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$SERVICE" --region us-east-1 \
         --image-tag-mutability MUTABLE --image-scanning-configuration scanOnPush=true >/dev/null

  if [ "$TAG" != "latest" ]; then
    echo "🚀 Pushing $SERVICE to ECR (latest, and pinned tag $TAG)..."
    docker push "${ECR_REGISTRY}/${SERVICE}:latest"
    docker push "${ECR_REGISTRY}/${SERVICE}:${TAG}"
  else
    echo "🚀 Pushing $SERVICE to ECR (latest)..."
    docker push "${ECR_REGISTRY}/${SERVICE}:latest"
  fi
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
# Hash generated at runtime from ARGOCD_ADMIN_PASSWORD (secrets.env) rather
# than a pre-computed hash pasted into this script — a hand-regenerated
# hash has silently drifted from the intended plaintext before (confirmed
# live: previous sessions' hardcoded hashes required manual bcrypt
# recomputation every time the password changed, with no way to catch a
# mistake until someone actually tried to log in). ARGOCD_ADMIN_HASH is a
# real bash variable, so its `$`-prefixed bcrypt segments (e.g. "$2b$10$...")
# are substituted verbatim below — not re-parsed as shell expansions.
ARGOCD_ADMIN_HASH=$(argocd account bcrypt --password "$ARGOCD_ADMIN_PASSWORD")
kubectl patch secret argocd-secret -n argocd \
  -p "{\"stringData\": {
    \"admin.password\": \"${ARGOCD_ADMIN_HASH}\",
    \"admin.passwordMtime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }}"

kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd

# install.yaml (applied above) always creates this with a random generated
# password. Once the fixed admin.password patch above is live and the
# server's picked it up, this initial secret is a stale, unused alternate
# credential (ArgoCD itself only reads it to bootstrap admin.password on
# first install, never again afterward) — delete it so it can't be logged
# into. --ignore-not-found: harmless on a re-run of bootstrap.sh where it's
# already gone.
echo -e "\n🔹 Removing the auto-generated initial admin secret (fixed password patch above supersedes it)..."
kubectl delete secret argocd-initial-admin-secret -n argocd --ignore-not-found

# Don't just trust the patch — prove admin/$ARGOCD_ADMIN_PASSWORD actually
# authenticates, the same way a human would (`argocd login`), before
# bootstrap.sh reports success. Ephemeral port-forward + login attempt,
# retried: argocd-server's settings reload after the restart above isn't
# always instant.
echo -e "\n🔹 Verifying ArgoCD admin login with the configured password..."
kubectl port-forward svc/argocd-server -n argocd 18080:443 >/dev/null 2>&1 &
ARGOCD_VERIFY_PF_PID=$!
trap 'kill $ARGOCD_VERIFY_PF_PID 2>/dev/null || true' EXIT

elapsed=0
until argocd login 127.0.0.1:18080 --insecure --username admin --password "$ARGOCD_ADMIN_PASSWORD" >/dev/null 2>&1; do
  if [ "$elapsed" -ge 60 ]; then
    echo "❌ 'argocd login' with the configured admin password failed after ${elapsed}s."
    echo "   Check 'kubectl get secret argocd-secret -n argocd -o yaml' and 'kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server'."
    kill "$ARGOCD_VERIFY_PF_PID" 2>/dev/null || true
    trap - EXIT
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
argocd logout 127.0.0.1:18080 >/dev/null 2>&1 || true
kill "$ARGOCD_VERIFY_PF_PID" 2>/dev/null || true
trap - EXIT
echo "✅ Verified: admin login succeeds with the configured password."

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

# Blocks until an ArgoCD Application resource exists — bounded, with a
# clear timeout message instead of hanging bootstrap.sh forever if an
# earlier-wave app is stuck failing (a stuck wave won't retry itself).
wait_for_application_created() {
  local app="$1"
  local create_timeout="${2:-300}"
  local elapsed=0

  echo "⌛ Waiting for '$app' Application resource to be created by ArgoCD..."
  until kubectl get application "$app" -n argocd >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$create_timeout" ]; then
      echo "❌ Timed out after ${create_timeout}s waiting for Application '$app' to be created by ArgoCD."
      echo "   Check 'kubectl get applications -n argocd' — an earlier-wave app may be stuck failing."
      exit 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
}

# Polls an existing ArgoCD Application until it reports Synced + Healthy —
# printing status periodically instead of blocking silently on one long
# `kubectl wait`, so a slow-but-progressing sync doesn't read as a hang, and
# a genuinely stuck one fails with a clear, actionable message instead of
# kubectl's raw timeout error.
wait_for_application_healthy() {
  local app="$1"
  local health_timeout="${2:-300}"
  local elapsed=0
  local interval=5
  local last_status=""

  echo "⌛ Waiting for '$app' to become Synced/Healthy (timeout ${health_timeout}s)..."
  while true; do
    local sync health status
    sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    status="sync=$sync health=$health"

    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      echo "✅ '$app' is Synced/Healthy."
      return 0
    fi

    # Print on every status change, and at least every ~30s so a run that's
    # genuinely still progressing doesn't look stalled.
    if [ "$status" != "$last_status" ] || [ $((elapsed % 30)) -eq 0 ]; then
      echo "   ...'$app' status: $status (${elapsed}s/${health_timeout}s)"
      last_status="$status"
    fi

    if [ "$elapsed" -ge "$health_timeout" ]; then
      echo "❌ Timed out after ${health_timeout}s waiting for '$app' to become Synced/Healthy (last status: $status)."
      echo "   Check 'kubectl get application $app -n argocd -o yaml' for details."
      exit 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

# Composes the two: wait for the Application to exist, then for it to turn
# Synced/Healthy. What every plain wait below actually wants.
wait_for_application() {
  wait_for_application_created "$1" "${2:-300}"
  wait_for_application_healthy "$1" "${3:-300}"
}

echo -e "\n🔹 Step 6: Waiting for Vault to become Synced/Healthy..."
# Vault alone, ahead of external-secrets/kafka: those two are unrelated to
# Vault and would only add avoidable delay before Step 7 can configure
# Vault — the longer that takes, the wider the window in which downstream
# ExternalSecrets (grafana-admin-credentials, crypto-db-external-secret)
# race Vault being populated.
wait_for_application "vault"

echo -e "\n🔹 Step 7: Initializing Vault (auth, policy, roles, secrets)..."
# `make vault-init` owns the actual init/secret-injection logic (port-
# forwarding Vault, confirming it's unsealed, running terraform apply
# against terraform/vault-config) so it can also be re-run standalone —
# e.g. after a dev-mode Vault restart wipes its in-memory state, without
# rerunning the rest of bootstrap.sh. Vault's Application being Healthy
# (Step 6) only means its Pod passed readiness; `make vault-init` confirms
# it's actually unsealed before Terraform starts writing to it.
make vault-init

echo -e "\n🔹 Step 8: Waiting for remaining Infrastructure apps to finish syncing..."
# kyverno added here (it wasn't waited on before): it's a wave-0 app like
# the other two, and kyverno-policies (Step 10) can't even be created until
# this one is Synced/Healthy, so any problem with it is best caught here
# with a clear message rather than surfacing later as a confusing timeout
# on kyverno-policies' create-wait.
for app in "external-secrets" "kafka" "kyverno"; do
  wait_for_application "$app"
done

echo -e "\n🔹 Step 9: Waiting for crypto-wallet-app and monitoring-stack to consume secrets and become Healthy..."
# monitoring-stack and grafana-secret.yaml's ExternalSecret both sync at
# wave "1" (see k8s/apps/monitoring-app.yaml), so root-app only creates the
# monitoring-stack Application once wave 0 — which includes crypto-wallet-app
# — is itself Synced/Healthy. crypto-wallet-app's own health depends on the
# terraform apply above too, so on a clean bootstrap neither Application is
# guaranteed to exist by the time this step starts; wait_for_application's
# bounded create-wait (default 300s) handles that the same way it does for
# the infra apps above — without it, a fresh cluster hits
# "applications.argoproj.io \"monitoring-stack\" not found".
for app in "crypto-wallet-app" "monitoring-stack"; do
  wait_for_application_created "$app"

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

  wait_for_application_healthy "$app"
done

echo -e "\n🔹 Step 10: Waiting for kyverno-policies to sync ClusterPolicy objects..."
# Wave "1" (see k8s/apps/kyverno-policies-app.yaml), same as
# monitoring-stack/crypto-wallet-app above — gated behind kyverno (wave 0,
# waited on in Step 8) actually registering the ClusterPolicy CRD and its
# admission webhook, so this Application's first sync can't race that
# install. Without this wait, bootstrap.sh could report success while this
# Application was still mid-retry — the exact gap that used to leave
# root-application looking OutOfSync after `make up` finished, with nothing
# left in the script to explain why.
wait_for_application "kyverno-policies"

echo -e "\n🔹 Step 11: Waiting for the ingress Applications and setting up local DNS..."
# ingress-nginx is a wave-0 app like vault/external-secrets/kafka (not waited
# on until now — nothing upstream of it depended on it being ready), and
# `ingress` (the actual Ingress objects) is wave "1" behind it — see
# k8s/apps/ingress-app.yaml for why. Both need to be healthy before the
# hostnames below mean anything.
for app in "ingress-nginx" "ingress"; do
  wait_for_application "$app"
done

# Best-effort: a fresh machine may not have run `make setup-hosts` yet, and
# this step needs sudo if /etc/hosts isn't user-writable — don't fail the
# whole bootstrap over it, just tell the operator to run it themselves.
./scripts/setup-hosts.sh || echo "⚠️  Could not update /etc/hosts automatically — run 'make setup-hosts' manually."

echo -e "\n=================================================="
echo "✅ Bootstrap script completed successfully!"
echo "=================================================="

echo -e "\n🌐 Local service URLs (run 'make ingress-forward' in another terminal first):"
printf "  %-14s %s\n" "ArgoCD"   "http://argocd.local:8080"
printf "  %-14s %s\n" "Grafana"  "http://grafana.local:8080"
printf "  %-14s %s\n" "Vault"    "http://vault.local:8080"
printf "  %-14s %s\n" "Wallet"   "http://wallet.local:8080"

END_TIME=$SECONDS
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS_REM=$((DURATION % 60))

echo -e "\n⏱️  Total Execution Time: ${MINUTES}m ${SECONDS_REM}s"