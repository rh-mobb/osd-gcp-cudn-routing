.DEFAULT_GOAL := help

VENV      := .venv
PYTHON    := $(VENV)/bin/python
PIP       := $(VENV)/bin/pip
KOPF      := $(VENV)/bin/kopf
IMAGE     ?= bgp-routing-controller:latest
TF_DIR     ?= ../../cluster_bgp_routing
IAM_TF_DIR ?= ../../controller_gcp_iam
NS         ?= bgp-routing-system

.PHONY: help
help:
	@echo "BGP routing controller (Python / kopf)"
	@echo ""
	@echo "  venv              Create virtualenv and install requirements"
	@echo "  run               One-shot reconciliation (reads Terraform outputs for env vars)"
	@echo "  watch             Run the long-lived operator (kopf event loop)"
	@echo "  cleanup           Delete controller Deployment (if any), peers, spoke, FRR, router labels"
	@echo "  build             Build the container image with podman (local)"
	@echo "  deploy-openshift  oc kustomize deploy/ | sed (WIF audience) | oc apply + build + rollout (needs controller_gcp_iam terraform output)"
	@echo "  lint              Run basic Python checks (syntax)"
	@echo "  clean             Remove virtualenv"
	@echo ""
	@echo "Environment:"
	@echo "  IMAGE       Container image tag   (default: $(IMAGE))"
	@echo "  TF_DIR      cluster_bgp_routing dir (default: $(TF_DIR))"
	@echo "  IAM_TF_DIR  controller_gcp_iam dir for WIF audience (default: $(IAM_TF_DIR))"
	@echo "  NS          OpenShift namespace    (default: $(NS))"
	@echo "  KUBECONFIG  Path to kubeconfig     (default: ~/.kube/config)"
	@echo ""
	@echo "Before 'make run': oc login to the cluster and gcloud auth application-default login."

$(VENV)/bin/activate: requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt
	@touch $(VENV)/bin/activate

.PHONY: venv
venv: $(VENV)/bin/activate

# Load Terraform outputs in one shell recipe. Avoid $(eval)/$(shell) here: Make
# may treat "$(terraform …)" as variable syntax; use backticks for command subst.
.PHONY: run
run: venv
	@echo "Reading config from terraform output ($(TF_DIR))..."
	@set -e; \
	TF_DIR="$(TF_DIR)"; \
	cd "$$TF_DIR"; \
	export GCP_PROJECT=`terraform output -raw gcp_project_id 2>/dev/null || true`; \
	export CLUSTER_NAME=`terraform output -raw cluster_name 2>/dev/null || true`; \
	export CLOUD_ROUTER_NAME=`terraform output -raw cloud_router_name 2>/dev/null || true`; \
	export CLOUD_ROUTER_REGION=`terraform output -raw gcp_region 2>/dev/null || true`; \
	export NCC_HUB_NAME=`terraform output -raw ncc_hub_name 2>/dev/null || true`; \
	export NCC_SPOKE_NAME=`terraform output -raw ncc_spoke_name 2>/dev/null || true`; \
	export FRR_ASN=`terraform output -raw frr_asn 2>/dev/null || true`; \
	export GOOGLE_APPLICATION_CREDENTIALS="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	export KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config}"; \
	echo "  GCP_PROJECT:         $$GCP_PROJECT"; \
	echo "  CLUSTER_NAME:        $$CLUSTER_NAME"; \
	echo "  CLOUD_ROUTER_NAME:   $$CLOUD_ROUTER_NAME"; \
	echo "  CLOUD_ROUTER_REGION: $$CLOUD_ROUTER_REGION"; \
	echo "  NCC_HUB_NAME:        $$NCC_HUB_NAME"; \
	echo "  NCC_SPOKE_NAME:      $$NCC_SPOKE_NAME"; \
	echo "  FRR_ASN:             $$FRR_ASN"; \
	echo ""; \
	test -n "$$CLOUD_ROUTER_NAME" || { echo "ERROR: CLOUD_ROUTER_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_HUB_NAME"      || { echo "ERROR: NCC_HUB_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_SPOKE_NAME"    || { echo "ERROR: NCC_SPOKE_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	cd "$(CURDIR)"; \
	PYTHONPATH="$(CURDIR)" $(PYTHON) -m bgp_routing_controller --once

.PHONY: watch
watch: venv
	@echo "Reading config from terraform output ($(TF_DIR))..."
	@set -e; \
	TF_DIR="$(TF_DIR)"; \
	cd "$$TF_DIR"; \
	export GCP_PROJECT=`terraform output -raw gcp_project_id 2>/dev/null || true`; \
	export CLUSTER_NAME=`terraform output -raw cluster_name 2>/dev/null || true`; \
	export CLOUD_ROUTER_NAME=`terraform output -raw cloud_router_name 2>/dev/null || true`; \
	export CLOUD_ROUTER_REGION=`terraform output -raw gcp_region 2>/dev/null || true`; \
	export NCC_HUB_NAME=`terraform output -raw ncc_hub_name 2>/dev/null || true`; \
	export NCC_SPOKE_NAME=`terraform output -raw ncc_spoke_name 2>/dev/null || true`; \
	export FRR_ASN=`terraform output -raw frr_asn 2>/dev/null || true`; \
	export GOOGLE_APPLICATION_CREDENTIALS="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	export KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config}"; \
	echo "  GCP_PROJECT:         $$GCP_PROJECT"; \
	echo "  CLUSTER_NAME:        $$CLUSTER_NAME"; \
	echo "  CLOUD_ROUTER_NAME:   $$CLOUD_ROUTER_NAME"; \
	echo "  CLOUD_ROUTER_REGION: $$CLOUD_ROUTER_REGION"; \
	echo "  NCC_HUB_NAME:        $$NCC_HUB_NAME"; \
	echo "  NCC_SPOKE_NAME:      $$NCC_SPOKE_NAME"; \
	echo "  FRR_ASN:             $$FRR_ASN"; \
	echo ""; \
	test -n "$$CLOUD_ROUTER_NAME" || { echo "ERROR: CLOUD_ROUTER_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_HUB_NAME"      || { echo "ERROR: NCC_HUB_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_SPOKE_NAME"    || { echo "ERROR: NCC_SPOKE_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	cd "$(CURDIR)"; \
	PYTHONPATH="$(CURDIR)" $(PYTHON) -m bgp_routing_controller

.PHONY: cleanup
cleanup: venv
	@echo "Reading config from terraform output ($(TF_DIR))..."
	@set -e; \
	TF_DIR="$(TF_DIR)"; \
	cd "$$TF_DIR"; \
	export GCP_PROJECT=`terraform output -raw gcp_project_id 2>/dev/null || true`; \
	export CLUSTER_NAME=`terraform output -raw cluster_name 2>/dev/null || true`; \
	export CLOUD_ROUTER_NAME=`terraform output -raw cloud_router_name 2>/dev/null || true`; \
	export CLOUD_ROUTER_REGION=`terraform output -raw gcp_region 2>/dev/null || true`; \
	export NCC_HUB_NAME=`terraform output -raw ncc_hub_name 2>/dev/null || true`; \
	export NCC_SPOKE_NAME=`terraform output -raw ncc_spoke_name 2>/dev/null || true`; \
	export FRR_ASN=`terraform output -raw frr_asn 2>/dev/null || true`; \
	export GOOGLE_APPLICATION_CREDENTIALS="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	export KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config}"; \
	echo "  GCP_PROJECT:         $$GCP_PROJECT"; \
	echo "  CLUSTER_NAME:        $$CLUSTER_NAME"; \
	echo "  CLOUD_ROUTER_NAME:   $$CLOUD_ROUTER_NAME"; \
	echo "  CLOUD_ROUTER_REGION: $$CLOUD_ROUTER_REGION"; \
	echo "  NCC_HUB_NAME:        $$NCC_HUB_NAME"; \
	echo "  NCC_SPOKE_NAME:      $$NCC_SPOKE_NAME"; \
	echo "  FRR_ASN:             $$FRR_ASN"; \
	echo ""; \
	test -n "$$CLOUD_ROUTER_NAME" || { echo "ERROR: CLOUD_ROUTER_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_HUB_NAME"      || { echo "ERROR: NCC_HUB_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	test -n "$$NCC_SPOKE_NAME"    || { echo "ERROR: NCC_SPOKE_NAME is empty. Run 'terraform apply' in $$TF_DIR first." >&2; exit 1; }; \
	cd "$(CURDIR)"; \
	PYTHONPATH="$(CURDIR)" $(PYTHON) -m bgp_routing_controller --cleanup

.PHONY: build
build:
	podman build -t $(IMAGE) .

# OpenShift: apply manifests, upload this directory as Docker context, push to internal registry.
.PHONY: deploy-openshift
deploy-openshift:
	@set -e; \
	WIF_AUD="$$(cd "$(IAM_TF_DIR)" && terraform output -raw wif_kubernetes_token_audience)"; \
	oc kustomize deploy/ | sed "s|__BGP_CONTROLLER_WIF_AUDIENCE__|$$WIF_AUD|g" | oc apply -f -
	oc start-build bgp-routing-controller -n "$(NS)" --from-dir=. --follow
	oc rollout status "deployment/bgp-routing-controller" -n "$(NS)" --timeout=180s

.PHONY: lint
lint: venv
	$(PYTHON) -m py_compile bgp_routing_controller/__init__.py
	$(PYTHON) -m py_compile bgp_routing_controller/__main__.py
	$(PYTHON) -m py_compile bgp_routing_controller/config.py
	$(PYTHON) -m py_compile bgp_routing_controller/gcp.py
	$(PYTHON) -m py_compile bgp_routing_controller/frr.py
	$(PYTHON) -m py_compile bgp_routing_controller/reconciler.py
	$(PYTHON) -m py_compile bgp_routing_controller/main.py
	@echo "All modules compile OK"

.PHONY: clean
clean:
	rm -rf $(VENV)
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
