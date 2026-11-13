.DEFAULT_GOAL := help
SHELL := /bin/bash

# Service repos are expected next to this one; `make repos` clones any that
# are missing.
REPOS_DIR ?= ..
GITHUB ?= https://github.com/learnercys
CLUSTER := platform
KIND ?= kind
HELM ?= helm
KUBECTL ?= kubectl
TF_IMAGE := hashicorp/terraform:1.14

EP := $(REPOS_DIR)/event-pipeline
LEDGER := $(REPOS_DIR)/ledger
GW := $(REPOS_DIR)/llm-gateway

.PHONY: help
help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: repos
repos: ## Clone the service repos next to this one if they're missing
	@for r in event-pipeline ledger llm-gateway; do \
		[ -d "$(REPOS_DIR)/$$r" ] || git clone -q --depth 1 $(GITHUB)/$$r "$(REPOS_DIR)/$$r"; done

.PHONY: up
up: repos cluster images preload deps observability apps ## Everything: cluster, images, dependencies, observability, services
	@echo
	@echo "Grafana         http://localhost:53000  (Dashboards > Platform)"
	@echo "event-pipeline  http://localhost:58080/v1/events"
	@echo "ledger          http://localhost:58090  (tokens: http://localhost:58180)"
	@echo "llm-gateway     http://localhost:58000/v1/complete"

.PHONY: cluster
cluster: ## Create the kind cluster
	@$(KIND) get clusters 2>/dev/null | grep -qx $(CLUSTER) || $(KIND) create cluster --config local/kind.yaml --wait 120s

.PHONY: images
images: ## Build the service images from the sibling repos and load them into kind
	docker build -q -t event-pipeline:local $(EP)
	docker build -q -t event-pipeline-analytics:local $(EP)/analytics
	docker build -q -t ledger:local $(LEDGER)
	docker build -q -t llm-gateway:local $(GW)
	$(KIND) load docker-image --name $(CLUSTER) \
		event-pipeline:local event-pipeline-analytics:local ledger:local llm-gateway:local

THIRD_PARTY := postgres:17-alpine redis:7-alpine motoserver/moto:5.2.5 quay.io/keycloak/keycloak:26.4 \
	grafana/otel-lgtm:0.40.0 otel/opentelemetry-collector-contrib:0.165.0

.PHONY: preload
preload: ## Copy third-party images already on this machine into kind (saves pulls)
	@for i in $(THIRD_PARTY); do docker image inspect $$i >/dev/null 2>&1 && \
		$(KIND) load docker-image --name $(CLUSTER) $$i >/dev/null 2>&1 && echo "preloaded $$i" || true; done

.PHONY: deps
deps: ## Postgres, Redis, Moto, Keycloak (local stand-ins for AWS services)
	$(HELM) upgrade --install deps charts/dev-deps -n deps --create-namespace --wait --timeout 5m \
		--set-file keycloak.realm=$(LEDGER)/deploy/keycloak/ledger-realm.json

.PHONY: observability
observability: ## OpenTelemetry Collector + Grafana/Prometheus/Tempo/Loki
	$(HELM) upgrade --install observability charts/observability -n observability --create-namespace --wait --timeout 5m

.PHONY: apps
apps: charts-deps ## Deploy the three services
	$(HELM) upgrade --install event-pipeline charts/event-pipeline -n event-pipeline --create-namespace \
		--wait --timeout 5m --set-file 'migrations.files.001_init\.sql=$(EP)/migrations/001_init.sql'
	$(HELM) upgrade --install ledger charts/ledger -n ledger --create-namespace \
		--wait --timeout 5m --set-file 'migrations.files.001_init\.sql=$(LEDGER)/migrations/001_init.sql'
	$(HELM) upgrade --install llm-gateway charts/llm-gateway -n llm-gateway --create-namespace \
		--wait --timeout 5m --set-file config=$(GW)/config/gateway.yaml \
		$(if $(ANTHROPIC_API_KEY),--set secretEnv.ANTHROPIC_API_KEY=$(ANTHROPIC_API_KEY))

.PHONY: charts-deps
charts-deps:
	@for c in event-pipeline ledger llm-gateway; do $(HELM) dependency update charts/$$c >/dev/null; done

.PHONY: smoke
smoke: ## End-to-end checks against the cluster using each repo's own tools
	./scripts/smoke.sh $(REPOS_DIR)

.PHONY: down
down: ## Delete the kind cluster
	$(KIND) delete cluster --name $(CLUSTER)

.PHONY: lint
lint: charts-deps ## helm lint, kubeconform on rendered manifests, terraform fmt/validate, tflint
	./scripts/lint.sh

.PHONY: tf-validate
tf-validate: ## terraform init (no backend) + validate the AWS environment
	docker run --rm -v $(CURDIR)/infra/terraform:/tf -w /tf/envs/staging $(TF_IMAGE) init -backend=false -input=false >/dev/null
	docker run --rm -v $(CURDIR)/infra/terraform:/tf -w /tf/envs/staging $(TF_IMAGE) validate
