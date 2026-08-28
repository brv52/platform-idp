SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= platform-idp
VERSION      ?= $(shell git rev-parse --short HEAD)
IMAGE        ?= localhost:5001/demo-api
TF           ?= $(shell command -v terraform || command -v tofu)

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

.PHONY: image
image: ## Build the demo-api image (reproducible timestamps from the last commit)
	docker buildx build --load \
	  --build-arg VERSION=$(VERSION) \
	  --build-arg SOURCE_DATE_EPOCH=$$(git log -1 --format=%ct) \
	  -t $(IMAGE):$(VERSION) services/demo-api

.PHONY: lint
lint: ## Static checks: go vet, terraform fmt/validate, tflint, kyverno test
	cd services/demo-api && go vet ./...
	$(TF) fmt -check -recursive infra/terraform
	for env in infra/terraform/envs/*/; do (cd $$env && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate); done
	if command -v tflint >/dev/null; then cd infra/terraform && tflint --init --config "$$PWD/.tflint.hcl" >/dev/null && tflint --recursive --config "$$PWD/.tflint.hcl"; else echo "tflint not installed, skipping"; fi
	command -v kyverno >/dev/null && kyverno test policies/tests || echo "kyverno CLI not installed, skipping"

.PHONY: bench
bench: ## Run the full benchmark suite and render metrics.json + docs/results.md
	bench/run-all.sh
