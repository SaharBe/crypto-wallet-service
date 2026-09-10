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
SERVICES     := order-service wallet-service
SECRETS_ENV  := secrets.env

# Source secrets.env into the recipe shell when present; no-op when absent
# (targets that need a specific variable assert on it explicitly — see build).
LOAD_SECRETS := if [ -f $(SECRETS_ENV) ]; then set -a; . ./$(SECRETS_ENV); set +a; fi

.DEFAULT_GOAL := help
.PHONY: help up down build

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

build: ## Build & push Docker images for order-service and wallet-service to ECR
	@$(LOAD_SECRETS); \
	: "$${ECR_REGISTRY:?not set — add it to $(SECRETS_ENV) (copy $(SECRETS_ENV).example) or export it before running make}"; \
	echo "🔑 Logging in to AWS ECR ($(AWS_REGION))..."; \
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin "$${ECR_REGISTRY}"; \
	for svc in $(SERVICES); do \
		echo "📦 Building image for $$svc from ./services/$$svc..."; \
		docker build -t "$${ECR_REGISTRY}/$$svc:latest" "./services/$$svc"; \
		echo "🚀 Pushing $$svc to ECR..."; \
		docker push "$${ECR_REGISTRY}/$$svc:latest"; \
	done
