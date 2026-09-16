# ─────────────────────────────────────────────────────────────────────────────
# Root Makefile — developer-operations entrypoint for the crypto-wallet IDP.
#
# Run every target from the repo root. Plain `make` (or `make help`) lists
# the targets.
#
# secrets.env is picked up automatically when it exists — no need to
# `source secrets.env` first. It is shell syntax (`export FOO="bar"`, plus
# `$VAR` cross-references), so recipes `.`-source it in the shell rather than
# Make `include`-ing it: a bare `include` keeps the literal quotes (which
# then break `docker login` / `docker build -t`) and mis-expands the `$VAR`
# references (`$REPO_URL` -> `EPO_URL`, etc.).
# ─────────────────────────────────────────────────────────────────────────────

TF_INFRA_DIR := terraform/infra
AWS_REGION   ?= us-east-1
SERVICES     := order-service wallet-service frontend
SECRETS_ENV  := secrets.env

# k6 performance tests — see tests/performance/. K6_SCRIPT picks which one;
# K6_MODE=local runs against BASE_URL (default: a port-forwarded frontend
# Service) via a local k6 binary or, if missing, the grafana/k6 Docker
# image; K6_MODE=cluster runs it in-cluster as an ephemeral Pod instead
# (tests/performance/run-in-cluster.sh), hitting the frontend Service
# directly with no port-forward involved.
K6_SCRIPT ?= load-test.js
K6_MODE   ?= local
BASE_URL  ?= http://localhost:8080

# Source secrets.env into the recipe shell when present; no-op when absent
# (targets that need a specific variable assert on it explicitly — see build).
LOAD_SECRETS := if [ -f $(SECRETS_ENV) ]; then set -a; . ./$(SECRETS_ENV); set +a; fi

.DEFAULT_GOAL := help
.PHONY: help up down build vault-init test-load setup-hosts ingress-forward

help: ## Show this help
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

up: ## Spin up the entire stack (runs ./bootstrap.sh)
	./bootstrap.sh

down: ## Tear down AWS infrastructure — terraform destroy, auto-approved
	terraform -chdir=$(TF_INFRA_DIR) destroy --auto-approve

setup-hosts: ## Add argocd.local/grafana.local/vault.local/wallet.local to /etc/hosts (sudo if needed)
	@./scripts/setup-hosts.sh

ingress-forward: ## Port-forward the ingress-nginx controller to localhost:8080 — leave running, then browse *.local:8080 (run `make setup-hosts` first)
	@echo "🔌 Forwarding svc/ingress-nginx-controller (ingress-nginx ns) -> http://localhost:8080"; \
	echo "   Ctrl+C to stop. Browse: http://argocd.local:8080  http://grafana.local:8080  http://vault.local:8080  http://wallet.local:8080"; \
	kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx 8080:80

vault-init: ## Configure Vault (auth, policies, roles, secrets) via Terraform — safe to re-run
	@$(LOAD_SECRETS); \
	: "$${VAULT_TOKEN:?not set — add it to $(SECRETS_ENV) (copy $(SECRETS_ENV).example)}"; \
	export TF_VAR_vault_token="$$VAULT_TOKEN"; \
	export TF_VAR_db_username="$$DB_USERNAME"; \
	export TF_VAR_db_password="$$DB_PASSWORD"; \
	export TF_VAR_github_username="$$GITHUB_USERNAME"; \
	export TF_VAR_github_pat="$$GITHUB_PAT"; \
	export TF_VAR_repo_url="$$REPO_URL"; \
	echo "🔌 Port-forwarding Vault so Terraform can reach it from outside the cluster..."; \
	kubectl port-forward svc/vault -n vault 8200:8200 > /dev/null 2>&1 & \
	VAULT_PF_PID=$$!; \
	trap 'kill $$VAULT_PF_PID 2>/dev/null || true' EXIT; \
	echo "⌛ Waiting for Vault to report initialized and unsealed..."; \
	elapsed=0; \
	until curl -s http://127.0.0.1:8200/v1/sys/health 2>/dev/null | grep -q '"sealed":false'; do \
		if [ "$$elapsed" -ge 120 ]; then \
			echo "❌ Timed out after 120s waiting for Vault to unseal."; \
			echo "   Check 'kubectl logs -n vault -l app.kubernetes.io/name=vault'."; \
			exit 1; \
		fi; \
		sleep 2; elapsed=$$((elapsed + 2)); \
	done; \
	echo "✅ Vault is initialized and unsealed."; \
	terraform -chdir=terraform/vault-config init -backend-config=backend.hcl -input=false; \
	terraform -chdir=terraform/vault-config apply --auto-approve; \
	echo "✅ Vault configured successfully via Terraform!"

build: ## Build & push Docker images for every service in $(SERVICES) to ECR
	@$(LOAD_SECRETS); \
	: "$${ECR_REGISTRY:?not set — add it to $(SECRETS_ENV) (copy $(SECRETS_ENV).example) or export it before running make}"; \
	echo "🔑 Logging in to AWS ECR ($(AWS_REGION))..."; \
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin "$${ECR_REGISTRY}"; \
	for svc in $(SERVICES); do \
		echo "📦 Building image for $$svc from ./services/$$svc..."; \
		manifest="k8s/components/$$svc.yaml"; \
		tag=$$(sed -n "s#.*/$$svc:\([^[:space:]\"']*\).*#\1#p" "$$manifest" | head -1); \
		tag="$${tag:-latest}"; \
		docker build -t "$${ECR_REGISTRY}/$$svc:latest" "./services/$$svc"; \
		if [ "$$tag" != "latest" ]; then docker tag "$${ECR_REGISTRY}/$$svc:latest" "$${ECR_REGISTRY}/$$svc:$$tag"; fi; \
		echo "🔎 Ensuring ECR repository '$$svc' exists ($(AWS_REGION))..."; \
		aws ecr describe-repositories --repository-names "$$svc" --region $(AWS_REGION) >/dev/null 2>&1 \
			|| aws ecr create-repository --repository-name "$$svc" --region $(AWS_REGION) \
				--image-tag-mutability MUTABLE --image-scanning-configuration scanOnPush=true >/dev/null; \
		if [ "$$tag" != "latest" ]; then \
			echo "🚀 Pushing $$svc to ECR (latest, and pinned tag $$tag)..."; \
			docker push "$${ECR_REGISTRY}/$$svc:latest"; \
			docker push "$${ECR_REGISTRY}/$$svc:$$tag"; \
		else \
			echo "🚀 Pushing $$svc to ECR (latest)..."; \
			docker push "$${ECR_REGISTRY}/$$svc:latest"; \
		fi; \
	done

test-load: ## Run k6 load tests. K6_SCRIPT=load-test.js|spike-test.js|kafka-pipeline-stress.js (default load-test.js), K6_MODE=local|cluster (default local), BASE_URL=... (local mode only; default http://localhost:8080 — run `kubectl port-forward svc/frontend 8080:80 -n crypto-wallet-app` first)
	@if [ "$(K6_MODE)" = "cluster" ]; then \
		./tests/performance/run-in-cluster.sh "$(K6_SCRIPT)"; \
	elif command -v k6 >/dev/null 2>&1; then \
		echo "🚀 Running $(K6_SCRIPT) locally against $(BASE_URL)..."; \
		BASE_URL="$(BASE_URL)" k6 run "tests/performance/$(K6_SCRIPT)"; \
	else \
		echo "🐳 k6 not found locally — running $(K6_SCRIPT) via the grafana/k6 Docker image against $(BASE_URL)..."; \
		docker run --rm -i --network host \
			-e BASE_URL="$(BASE_URL)" \
			-v "$$(pwd)/tests/performance:/scripts" \
			grafana/k6:latest run "/scripts/$(K6_SCRIPT)"; \
	fi
