.DEFAULT_GOAL := help

IMAGE   ?= bgp-routing-controller:latest
TF_DIR  ?= ../../cluster_bgp_routing
IAM_TF_DIR ?= ../../controller_gcp_iam
NS      ?= bgp-routing-system
CONTROLLER_TF_ENV_SCRIPT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../scripts/terraform-controller-env-from-json.sh)

.PHONY: help
help:
	@echo "BGP routing controller (Go / controller-runtime)"
	@echo ""
	@echo "  build            Compile bin/manager"
	@echo "  test             go test ./..."
	@echo "  fmt              gofmt -w ."
	@echo "  vet              go vet ./..."
	@echo "  run              One-shot reconcile (terraform outputs -> env)"
	@echo "  watch            Run manager (needs KUBECONFIG + ADC)"
	@echo "  cleanup          Full cleanup (--cleanup)"
	@echo "  docker-build     podman/docker build -t \$$(IMAGE)"
	@echo "  deploy-print     kustomize build deploy/"
	@echo "  deploy-openshift oc kustomize deploy/ | sed WIF | oc apply + binary build + rollout"
	@echo ""
	@echo "  TF_DIR=$(TF_DIR)  IAM_TF_DIR=$(IAM_TF_DIR)  NS=$(NS)  IMAGE=$(IMAGE)"

.PHONY: build
build:
	go build -o bin/manager ./cmd/main.go

.PHONY: test
test:
	go test ./... -count=1

.PHONY: fmt
fmt:
	gofmt -w .

.PHONY: vet
vet:
	go vet ./...

# Load Terraform outputs in one shell recipe (same pattern as controller/python/Makefile).
.PHONY: run
run:
	@echo "Reading config from terraform output ($(TF_DIR))..."
	@set -e; \
	TF_DIR="$(TF_DIR)"; \
	cd "$$TF_DIR"; \
	eval "$$($(CONTROLLER_TF_ENV_SCRIPT))"; \
	export GOOGLE_APPLICATION_CREDENTIALS="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	export KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config}"; \
	test -n "$$CLOUD_ROUTER_NAME" || { echo "ERROR: CLOUD_ROUTER_NAME empty. Apply terraform in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_HUB_NAME"      || { echo "ERROR: NCC_HUB_NAME empty." >&2; exit 1; }; \
	test -n "$$NCC_SPOKE_PREFIX"  || { echo "ERROR: NCC_SPOKE_PREFIX empty." >&2; exit 1; }; \
	cd "$(CURDIR)"; \
	go run ./cmd/main.go --once

.PHONY: watch
watch:
	@echo "Reading config from terraform output ($(TF_DIR))..."
	@set -e; \
	TF_DIR="$(TF_DIR)"; \
	cd "$$TF_DIR"; \
	eval "$$($(CONTROLLER_TF_ENV_SCRIPT))"; \
	export GOOGLE_APPLICATION_CREDENTIALS="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	export KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config}"; \
	test -n "$$CLOUD_ROUTER_NAME" || { echo "ERROR: CLOUD_ROUTER_NAME empty." >&2; exit 1; }; \
	test -n "$$NCC_HUB_NAME"      || { echo "ERROR: NCC_HUB_NAME empty." >&2; exit 1; }; \
	test -n "$$NCC_SPOKE_PREFIX"  || { echo "ERROR: NCC_SPOKE_PREFIX empty." >&2; exit 1; }; \
	cd "$(CURDIR)"; \
	go run ./cmd/main.go

.PHONY: cleanup
cleanup:
	@set -e; \
	TF_DIR="$(TF_DIR)"; \
	cd "$$TF_DIR"; \
	eval "$$($(CONTROLLER_TF_ENV_SCRIPT))"; \
	export GOOGLE_APPLICATION_CREDENTIALS="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	export KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config}"; \
	if [ -z "$$CLOUD_ROUTER_NAME" ]; then \
	  echo "WARN: cluster Terraform has no outputs under $$TF_DIR (CLOUD_ROUTER_NAME empty). Skipping controller --cleanup; continue teardown (e.g. cluster stack already destroyed). If the controller ran, remove in-cluster resources manually if needed." >&2; \
	  exit 0; \
	fi; \
	cd "$(CURDIR)"; \
	go run ./cmd/main.go --cleanup

.PHONY: docker-build
docker-build:
	podman build -t $(IMAGE) .

.PHONY: deploy-print
deploy-print:
	@kubectl kustomize deploy/

.PHONY: deploy-openshift
deploy-openshift:
	@set -e; \
	WIF_AUD="$$(cd "$(IAM_TF_DIR)" && terraform output -raw wif_kubernetes_token_audience)"; \
	INTERNAL_IMG='image-registry.openshift-image-registry.svc:5000/bgp-routing-system/bgp-routing-controller:latest'; \
	oc kustomize deploy/ | sed -e "s|__BGP_CONTROLLER_WIF_AUDIENCE__|$$WIF_AUD|g" -e "s|__BGP_CONTROLLER_IMAGE__|$$INTERNAL_IMG|g" | oc apply -f -; \
	oc start-build bgp-routing-controller -n "$(NS)" --from-dir="$(CURDIR)" --follow; \
	oc rollout restart "deployment/bgp-routing-controller" -n "$(NS)"; \
	oc rollout status "deployment/bgp-routing-controller" -n "$(NS)" --timeout=600s
