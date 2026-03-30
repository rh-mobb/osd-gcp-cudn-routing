.DEFAULT_GOAL := help

VENV      := .venv
PYTHON    := $(VENV)/bin/python
PIP       := $(VENV)/bin/pip
KOPF      := $(VENV)/bin/kopf
IMAGE     ?= bgp-routing-controller:latest
TF_DIR    ?= ../../cluster_bgp_routing

.PHONY: help
help:
	@echo "BGP routing controller (Python / kopf)"
	@echo ""
	@echo "  venv        Create virtualenv and install requirements"
	@echo "  run         One-shot reconciliation (reads Terraform outputs for env vars)"
	@echo "  watch       Run the long-lived operator (kopf event loop)"
	@echo "  cleanup     Delete all controller-managed resources (peers, spoke, FRR)"
	@echo "  build       Build the container image with podman"
	@echo "  lint        Run basic Python checks (syntax)"
	@echo "  clean       Remove virtualenv"
	@echo ""
	@echo "Environment:"
	@echo "  IMAGE       Container image tag   (default: $(IMAGE))"
	@echo "  TF_DIR      Terraform output dir   (default: $(TF_DIR))"
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

# Reads Terraform outputs into env vars and validates required ones are set.
define load-tf-env
	$(eval export GCP_PROJECT         := $(shell cd $(TF_DIR) && terraform output -raw gcp_project_id 2>/dev/null))
	$(eval export CLUSTER_NAME        := $(shell cd $(TF_DIR) && terraform output -raw cluster_name 2>/dev/null))
	$(eval export CLOUD_ROUTER_NAME   := $(shell cd $(TF_DIR) && terraform output -raw cloud_router_name 2>/dev/null))
	$(eval export CLOUD_ROUTER_REGION := $(shell cd $(TF_DIR) && terraform output -raw gcp_region 2>/dev/null))
	$(eval export NCC_HUB_NAME        := $(shell cd $(TF_DIR) && terraform output -raw ncc_hub_name 2>/dev/null))
	$(eval export NCC_SPOKE_NAME      := $(shell cd $(TF_DIR) && terraform output -raw ncc_spoke_name 2>/dev/null))
	$(eval export FRR_ASN             := $(shell cd $(TF_DIR) && terraform output -raw frr_asn 2>/dev/null))
	$(eval export GOOGLE_APPLICATION_CREDENTIALS ?= $(HOME)/.config/gcloud/application_default_credentials.json)
	$(eval export KUBECONFIG          ?= $(HOME)/.kube/config)
	@echo "  GCP_PROJECT:         $(GCP_PROJECT)"
	@echo "  CLUSTER_NAME:        $(CLUSTER_NAME)"
	@echo "  CLOUD_ROUTER_NAME:   $(CLOUD_ROUTER_NAME)"
	@echo "  CLOUD_ROUTER_REGION: $(CLOUD_ROUTER_REGION)"
	@echo "  NCC_HUB_NAME:        $(NCC_HUB_NAME)"
	@echo "  NCC_SPOKE_NAME:      $(NCC_SPOKE_NAME)"
	@echo "  FRR_ASN:             $(FRR_ASN)"
	@echo ""
	@test -n "$(CLOUD_ROUTER_NAME)" || { echo "ERROR: CLOUD_ROUTER_NAME is empty. Run 'terraform apply' in $(TF_DIR) first."; exit 1; }
	@test -n "$(NCC_HUB_NAME)"      || { echo "ERROR: NCC_HUB_NAME is empty. Run 'terraform apply' in $(TF_DIR) first."; exit 1; }
	@test -n "$(NCC_SPOKE_NAME)"    || { echo "ERROR: NCC_SPOKE_NAME is empty. Run 'terraform apply' in $(TF_DIR) first."; exit 1; }
endef

.PHONY: run
run: venv
	@echo "Reading config from terraform output ($(TF_DIR))..."
	$(load-tf-env)
	PYTHONPATH="$(CURDIR)" $(PYTHON) -m bgp_routing_controller --once

.PHONY: watch
watch: venv
	@echo "Reading config from terraform output ($(TF_DIR))..."
	$(load-tf-env)
	PYTHONPATH="$(CURDIR)" $(PYTHON) -m bgp_routing_controller

.PHONY: cleanup
cleanup: venv
	@echo "Reading config from terraform output ($(TF_DIR))..."
	$(load-tf-env)
	PYTHONPATH="$(CURDIR)" $(PYTHON) -m bgp_routing_controller --cleanup

.PHONY: build
build:
	podman build -t $(IMAGE) .

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
