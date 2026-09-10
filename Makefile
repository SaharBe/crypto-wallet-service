# ─────────────────────────────────────────────────────────────────────────────
# Root Makefile — developer-operations entrypoint for the crypto-wallet IDP.
#
# Run every target from the repo root. Plain `make` (or `make help`) lists
# the targets. `up` and `build` expect secrets.env to be sourced first, e.g.:
#
#     source secrets.env && make build
# ─────────────────────────────────────────────────────────────────────────────

TF_INFRA_DIR := terraform/infra
AWS_REGION   ?= us-east-1
SERVICES     := order-service wallet-service

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
	@: $${ECR_REGISTRY:?ECR_REGISTRY not set — run 'source secrets.env' first}; \
	echo "🔑 Logging in to AWS ECR ($(AWS_REGION))..."; \
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin "$${ECR_REGISTRY}"; \
	for svc in $(SERVICES); do \
		echo "📦 Building image for $$svc from ./services/$$svc..."; \
		docker build -t "$${ECR_REGISTRY}/$$svc:latest" "./services/$$svc"; \
		echo "🚀 Pushing $$svc to ECR..."; \
		docker push "$${ECR_REGISTRY}/$$svc:latest"; \
	done
