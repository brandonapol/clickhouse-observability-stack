SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

HELM_VERSION := v3.22.0
KUBECONFORM_VERSION := v0.8.0
YQ_VERSION := v4.54.1
ACTIONLINT_VERSION := v1.7.12
YAMLLINT_VERSION := 1.38.0
SHELLCHECK_VERSION := 0.11.0.1
HELM_UNITTEST_VERSION := v1.1.2
KUBE_VERSION := 1.34.0
GOLDEN := tests/golden

LOCAL_CHARTS := $(patsubst %/Chart.yaml,%,$(wildcard cluster-nodes/*/Chart.yaml tests/charts/*/Chart.yaml))
UNIT_TEST_CHARTS := $(patsubst %/tests/,%,$(dir $(wildcard cluster-configs/app-of-apps/tests/*_test.yaml cluster-nodes/*/tests/*_test.yaml tests/charts/*/tests/*_test.yaml)))

VENV := .venv

SHELL_SCRIPTS := $(wildcard scripts/*.sh scripts/*.bash) git/hooks/pre-commit

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_\/-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Setup

.PHONY: setup
setup: setup/tools setup/hooks ## Install every tool the checks need, plus the git hooks

.PHONY: setup/tools
setup/tools: setup/tools/go setup/tools/helm-unittest setup/tools/python setup/tools/node ## Install helm, helm-unittest, kubeconform, yq, actionlint, yamllint, shellcheck, cspell

.PHONY: setup/tools/go
setup/tools/go:
	go install helm.sh/helm/v3/cmd/helm@$(HELM_VERSION)
	go install github.com/yannh/kubeconform/cmd/kubeconform@$(KUBECONFORM_VERSION)
	go install github.com/mikefarah/yq/v4@$(YQ_VERSION)
	go install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)

.PHONY: setup/tools/helm-unittest
setup/tools/helm-unittest:
	tmp="$$(mktemp -d)" && \
	git clone -q --depth 1 --branch $(HELM_UNITTEST_VERSION) https://github.com/helm-unittest/helm-unittest "$$tmp" && \
	(cd "$$tmp" && go build -o "$$(go env GOPATH)/bin/helm-unittest" ./cmd/helm-unittest) && \
	rm -rf "$$tmp"

.PHONY: setup/tools/python
setup/tools/python:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --disable-pip-version-check \
		yamllint==$(YAMLLINT_VERSION) shellcheck-py==$(SHELLCHECK_VERSION)

.PHONY: setup/tools/node
setup/tools/node:
	npm ci --no-audit --no-fund

.PHONY: setup/hooks
setup/hooks: ## Point git at git/hooks so the pre-commit check runs
	git config core.hooksPath git/hooks

##@ Checks

.PHONY: check
check: check/lint check/golden check/manifests ## The whole gate CI runs

.PHONY: check/lint
check/lint: check/yaml check/shell check/structure check/workflows check/spelling ## Offline checks, what the pre-commit hook runs

.PHONY: check/yaml
check/yaml: ## yamllint every YAML file against .yamllint.yaml
	$(VENV)/bin/yamllint --strict .

.PHONY: check/shell
check/shell: ## shellcheck every script
	$(VENV)/bin/shellcheck $(SHELL_SCRIPTS)

.PHONY: check/structure
check/structure: ## Enforce the cluster-configs and cluster-nodes layout in AGENTS.md
	scripts/check-structure.bash

.PHONY: check/golden
check/golden: deps ## Fail when tests/golden differs from a fresh render
	@tmp="$$(mktemp -d)" && trap 'rm -rf "$$tmp"' EXIT && \
	KUBE_VERSION=$(KUBE_VERSION) scripts/render.bash "$$tmp" && \
	if ! diff -ru $(GOLDEN) "$$tmp"; then \
		echo "tests/golden is stale: run make generate and commit the result"; exit 1; \
	fi

.PHONY: check/workflows
check/workflows: ## actionlint the GitHub Actions workflows
	actionlint

.PHONY: check/spelling
check/spelling: ## cspell against cspell.json (American and British English)
	npm run --silent spell

.PHONY: check/manifests
check/manifests: ## kubeconform tests/golden against pinned schemas; require memory limits and pinned images
	KUBE_VERSION=$(KUBE_VERSION) scripts/check-manifests.bash

##@ Generate

.PHONY: generate
generate: deps ## Re-render tests/golden: every node, as Argo CD would deploy it, for every environment
	rm -rf $(GOLDEN)
	KUBE_VERSION=$(KUBE_VERSION) scripts/render.bash $(GOLDEN)

##@ Tests

.PHONY: deps
deps: ## Rebuild every local chart's file:// dependencies from Chart.lock
	@for chart in $(sort $(LOCAL_CHARTS)); do \
		helm dependency build "$$chart" >/dev/null || exit 1; \
	done

.PHONY: test
test: test/unit ## Every offline test

.PHONY: test/unit
test/unit: deps ## helm-unittest suites for the common library and every cluster node
	helm-unittest --strict $(sort $(UNIT_TEST_CHARTS))

##@ Local cluster

.PHONY: cluster/up
cluster/up: ## Create the kind cluster, install Argo CD and apply the root app
	scripts/kind-up.sh

.PHONY: cluster/down
cluster/down: ## Delete the kind cluster
	scripts/kind-down.sh

.PHONY: cluster/port-forward
cluster/port-forward: ## Forward Grafana, Argo CD, Cerberus and OTLP to localhost
	scripts/port-forward.sh
