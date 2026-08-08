SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= platform-idp

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Verify pinned versions exist upstream and regenerate docs/versions.md
	hack/preflight.sh --write

.PHONY: bootstrap
bootstrap: ## Create the local kind cluster and hand it to Argo CD
	CLUSTER_NAME=$(CLUSTER_NAME) clusters/local/bootstrap.sh

.PHONY: teardown
teardown: ## Delete the local kind cluster
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: test
test: ## Run Go unit tests
	cd services/demo-api && go test -race ./...

.PHONY: lint
lint: ## Static checks: go vet, terraform fmt/validate, tflint, kyverno test
	cd services/demo-api && go vet ./...
	tofu fmt -check -recursive infra/terraform
	for env in infra/terraform/envs/*/; do (cd $$env && tofu init -backend=false -input=false >/dev/null && tofu validate); done
	command -v tflint >/dev/null && tflint --chdir=infra/terraform --recursive || echo "tflint not installed, skipping"
	command -v kyverno >/dev/null && kyverno test policies/kyverno || echo "kyverno CLI not installed, skipping"

.PHONY: bench
bench: ## Run the full benchmark suite and render metrics.json + docs/results.md
	bench/run-all.sh
