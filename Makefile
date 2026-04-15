#
# Copyright (c) 2025 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

.DEFAULT_GOAL := help

CLUSTER_BGP_DIR := cluster_bgp_routing
ARCHIVE_ILB_DIR := archive/cluster_ilb_routing
WIF_DIR := wif_config
# Optional flags for wif.undelete-soft-deleted-roles (default: auto from wif_config Terraform + gcloud list --show-deleted).
# Examples: WIF_UNDELETE_ARGS='--dry-run'  WIF_UNDELETE_ARGS='--from-log ./apply.log'  WIF_UNDELETE_TERRAFORM_DIR=../other/wif
WIF_UNDELETE_ARGS ?=
CONTROLLER_DIR := controller/go
CONTROLLER_GCP_IAM_DIR := controller_gcp_iam
MODULES := $(sort $(notdir $(wildcard modules/*/)))

# Optional extra terraform CLI args (e.g. TF_VARS="-var-file=custom.tfvars").
TF_VARS :=
EXTRA_TF_VARS ?=

.PHONY: help
help:
	@echo "OSD GCP CUDN routing — BGP reference stack (Terraform)"
	@echo ""
	@echo "  (ILB reference stack lives under archive/ — see archive/README.md and archive/scripts/ilb-*.sh.)"
	@echo ""
	@echo "  create        bgp.run + bgp.deploy-controller (GHCR image); prints oc get nodes … + make bgp.e2e reminder (does not run e2e)"
	@echo "  dev           bgp.run + in-cluster binary build; same reminder as create (does not run e2e)"
	@echo "  post-controller-deploy-msg  print watch oc get nodes (BGP label, Ready) / make bgp.e2e (after deploy-controller)"
	@echo "  destroy       bgp.destroy-controller + bgp.teardown (full stack teardown; all terraform destroy steps use -auto-approve)"
	@echo ""
	@echo "  bgp.run       full deploy: WIF, cluster single apply (BGP+NCC+echo VM), oc login, cluster_bgp_routing configure-routing.sh"
	@echo "  bgp.teardown  terraform destroy $(CLUSTER_BGP_DIR)/ then $(WIF_DIR)/ (-auto-approve); run bgp.destroy-controller first if you used the in-cluster controller"
	@echo "  bgp.e2e       CUDN pod ↔ echo VM checks ($(CLUSTER_BGP_DIR)/; requires oc + gcloud logged in)"
	@echo "  bgp.phase1-baseline  fix-bgp-ra Phase 1: router nodes, RA nodeSelector, FRR CRs, debug-gcp-bgp (oc + terraform + gcloud)"
	@echo "  bgp.deploy-controller  After bgp.run: IAM + WIF Secret + ConfigMap from TF + (build or prebuilt image) + rollout"
	@echo "  bgp.destroy-controller  controller.cleanup then controller_gcp_iam terraform destroy -auto-approve (before bgp.teardown)"
	@echo ""
	@echo "  controller.venv      (Python only) Create venv under controller/python/"
	@echo "  controller.run       One-shot reconciliation (reads terraform output; Go controller)"
	@echo "  controller.watch     Run the long-lived controller (Go / controller-runtime)"
	@echo "  controller.test      go test ./... under controller/go"
	@echo "  controller.cleanup   Delete controller Deployment (if any), peers, NCC spokes, FRR, router labels (no-op with warning if cluster Terraform has no outputs)"
	@echo "  controller.build     Compile the Go controller binary (go build under $(CONTROLLER_DIR)/)"
	@echo "  controller.docker-build  Build the controller container image (podman; $(CONTROLLER_DIR)/Dockerfile)"
	@echo "  controller.deploy-openshift  Apply deploy/ + BuildConfig binary build + rollout"
	@echo "  controller.gcp-iam.* Terraform in $(CONTROLLER_GCP_IAM_DIR)/ (GCP SA + WIF bind; after WIF + cluster)"
	@echo "  controller.gcp-credentials  Generate credential-config.json (+ optional Secret via env)"
	@echo ""
	@echo "  wif.init      terraform init -upgrade in $(WIF_DIR)/"
	@echo "  wif.plan      terraform plan in $(WIF_DIR)/"
	@echo "  wif.apply     terraform apply in $(WIF_DIR)/ (run before cluster apply)"
	@echo "  wif.destroy   terraform destroy -auto-approve in $(WIF_DIR)/ (after cluster destroy)"
	@echo "  wif.undelete-soft-deleted-roles  Undelete soft-deleted WIF custom roles (reads wif_config/ Terraform + gcloud; optional WIF_UNDELETE_ARGS; see scripts/README.md)"
	@echo ""
	@echo "  init          terraform init -upgrade in $(CLUSTER_BGP_DIR)/ (same root as bgp.init)"
	@echo "  plan          terraform plan in $(CLUSTER_BGP_DIR)/"
	@echo "  apply         terraform apply in $(CLUSTER_BGP_DIR)/"
	@echo "  cluster.destroy  terraform destroy -auto-approve in $(CLUSTER_BGP_DIR)/ only (expert; not WIF / controller IAM)"
	@echo "  bgp.init      terraform init -upgrade in $(CLUSTER_BGP_DIR)/"
	@echo "  bgp.plan      terraform plan in $(CLUSTER_BGP_DIR)/"
	@echo "  bgp.apply     terraform apply in $(CLUSTER_BGP_DIR)/"
	@echo "  fmt           terraform fmt -recursive"
	@echo "  validate      terraform validate ($(WIF_DIR)/, modules, $(CLUSTER_BGP_DIR)/, $(CONTROLLER_GCP_IAM_DIR)/)"
	@echo "  clean         remove .terraform/ and lock files under repo"
	@echo ""
	@echo "WIF uses osd-wif-config from terraform-provider-osd-google (Git module source)."
	@echo "Provider rh-mobb/osd-google ~> 0.1.3 from Terraform Registry (no dev_overrides)."
	@echo "See README.md for prerequisites and workflow; scripts/README.md for bgp.run env vars."
	@echo "Naming: stack.action with dots; multi-word segments use hyphens (e.g. controller.gcp-iam.init)."

CREATE_CONTROLLER_IMAGE ?= ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-controller-go:latest
# Namespace for in-cluster controller (match BGP_CONTROLLER_NAMESPACE in bgp-deploy-controller-incluster.sh).
BGP_CONTROLLER_NAMESPACE ?= bgp-routing-system

.PHONY: create dev post-controller-deploy-msg destroy bgp.run bgp.teardown bgp.e2e bgp.phase1-baseline bgp.deploy-controller bgp.destroy-controller
post-controller-deploy-msg:
	@echo ""
	@echo "=== Controller deployed ($(BGP_CONTROLLER_NAMESPACE)/deployment/bgp-routing-controller) ==="
	@echo "Watch nodes with the BGP router label until every listed node has STATUS Ready (expected worker count), then run connectivity checks:"
	@echo "  watch 'oc get nodes -l cudn.redhat.com/bgp-router='"
	@echo "  (Ctrl+C to stop watch.)"
	@echo "  make bgp.e2e"

create:
	@$(MAKE) bgp.run
	@$(MAKE) bgp.deploy-controller BGP_CONTROLLER_PREBUILT_IMAGE="$(CREATE_CONTROLLER_IMAGE)"
	@$(MAKE) post-controller-deploy-msg

dev:
	@$(MAKE) bgp.run
	@$(MAKE) bgp.deploy-controller
	@$(MAKE) post-controller-deploy-msg

destroy:
	@echo "=== make destroy: full stack teardown ==="
	@echo ">>> Phase 1/2: bgp.destroy-controller (in-cluster cleanup + controller_gcp_iam/)"
	@$(MAKE) bgp.destroy-controller
	@echo ""
	@echo ">>> Phase 2/2: bgp.teardown (cluster_bgp_routing/ then wif_config/)"
	@$(MAKE) bgp.teardown
	@echo ""
	@echo "=== make destroy: finished ==="

bgp.run:
	@bash "$(CURDIR)/scripts/bgp-apply.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp.teardown:
	@echo ">>> bgp.teardown: scripts/bgp-destroy.sh"
	@bash "$(CURDIR)/scripts/bgp-destroy.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp.e2e:
	@bash "$(CURDIR)/scripts/e2e-cudn-connectivity.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

bgp.phase1-baseline:
	@bash "$(CURDIR)/scripts/bgp-phase1-baseline.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

bgp.deploy-controller:
	@bash "$(CURDIR)/scripts/bgp-deploy-controller-incluster.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp.destroy-controller:
	@echo "=== bgp.destroy-controller ==="
	@echo ">>> Step 1/2: controller.cleanup (OpenShift + GCP resources managed by the controller)"
	@$(MAKE) controller.cleanup
	@echo ""
	@echo ">>> Step 2/2: controller.gcp-iam.destroy (Terraform in $(CONTROLLER_GCP_IAM_DIR)/)"
	@$(MAKE) controller.gcp-iam.destroy
	@echo ""
	@echo "=== bgp.destroy-controller: finished ==="

.PHONY: wif.init wif.plan wif.apply wif.destroy wif.undelete-soft-deleted-roles
wif.init:
	@cd $(WIF_DIR) && terraform init -upgrade

wif.plan: wif.init
	@cd $(WIF_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

wif.apply: wif.init
	@cd $(WIF_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

wif.destroy: wif.init
	@cd $(WIF_DIR) && terraform destroy -auto-approve $(TF_VARS) $(EXTRA_TF_VARS)

wif.undelete-soft-deleted-roles:
	@bash "$(CURDIR)/scripts/gcp-undelete-wif-custom-roles.sh" $(WIF_UNDELETE_ARGS)

.PHONY: init
init:
	@cd $(CLUSTER_BGP_DIR) && terraform init -upgrade

.PHONY: plan
plan: init
	@cd $(CLUSTER_BGP_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: apply
apply: init
	@cd $(CLUSTER_BGP_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: cluster.destroy
cluster.destroy: init
	@cd $(CLUSTER_BGP_DIR) && terraform destroy -auto-approve $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: bgp.init bgp.plan bgp.apply
bgp.init:
	@cd $(CLUSTER_BGP_DIR) && terraform init -upgrade

bgp.plan: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

bgp.apply: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: controller.venv controller.run controller.watch controller.test controller.cleanup controller.build controller.docker-build controller.deploy-openshift
controller.venv:
	@$(MAKE) -C controller/python venv

controller.run:
	@$(MAKE) -C $(CONTROLLER_DIR) run

controller.watch:
	@$(MAKE) -C $(CONTROLLER_DIR) watch

controller.test:
	@$(MAKE) -C $(CONTROLLER_DIR) test

controller.cleanup:
	@echo ">>> controller.cleanup: $(CONTROLLER_DIR) (go run ... --cleanup)"
	@$(MAKE) -C $(CONTROLLER_DIR) cleanup

controller.build:
	@$(MAKE) -C $(CONTROLLER_DIR) build

controller.docker-build:
	@$(MAKE) -C $(CONTROLLER_DIR) docker-build

controller.deploy-openshift:
	@$(MAKE) -C $(CONTROLLER_DIR) deploy-openshift

.PHONY: controller.gcp-iam.init controller.gcp-iam.plan controller.gcp-iam.apply controller.gcp-iam.destroy controller.gcp-credentials
controller.gcp-iam.init:
	@cd $(CONTROLLER_GCP_IAM_DIR) && terraform init -upgrade

controller.gcp-iam.plan: controller.gcp-iam.init
	@cd $(CONTROLLER_GCP_IAM_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

controller.gcp-iam.apply: controller.gcp-iam.init
	@cd $(CONTROLLER_GCP_IAM_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

controller.gcp-iam.destroy: controller.gcp-iam.init
	@echo ">>> controller.gcp-iam.destroy: terraform destroy in $(CONTROLLER_GCP_IAM_DIR)/"
	@cd $(CONTROLLER_GCP_IAM_DIR) && terraform destroy -auto-approve $(TF_VARS) $(EXTRA_TF_VARS)

controller.gcp-credentials:
	@CONTROLLER_GCP_IAM_DIR="$(CURDIR)/$(CONTROLLER_GCP_IAM_DIR)" \
		bash "$(CURDIR)/scripts/bgp-controller-gcp-credentials.sh"

.PHONY: fmt
fmt:
	terraform fmt -recursive .

.PHONY: validate
validate:
	@echo "Validating $(WIF_DIR)..."
	@cd $(WIF_DIR) && terraform init -backend=false -input=false -upgrade && terraform validate
	@echo "Validating modules..."
	@for mod in $(MODULES); do \
	  echo "  modules/$$mod"; \
	  cd modules/$$mod && terraform init -backend=false -input=false -upgrade && terraform validate && cd ../.. || exit 1; \
	done
	@echo "Validating $(CLUSTER_BGP_DIR)..."
	@cd $(CLUSTER_BGP_DIR) && terraform init -backend=false -input=false -upgrade && terraform validate
	@echo "Validating $(CONTROLLER_GCP_IAM_DIR)..."
	@cd $(CONTROLLER_GCP_IAM_DIR) && terraform init -backend=false -input=false -upgrade && terraform validate

.PHONY: clean
clean:
	@rm -rf $(WIF_DIR)/.terraform $(WIF_DIR)/.terraform.lock.hcl
	@rm -rf $(ARCHIVE_ILB_DIR)/.terraform $(ARCHIVE_ILB_DIR)/.terraform.lock.hcl
	@rm -rf $(CLUSTER_BGP_DIR)/.terraform $(CLUSTER_BGP_DIR)/.terraform.lock.hcl
	@rm -rf $(CONTROLLER_GCP_IAM_DIR)/.terraform $(CONTROLLER_GCP_IAM_DIR)/.terraform.lock.hcl
	@for mod in $(MODULES); do rm -rf modules/$$mod/.terraform modules/$$mod/.terraform.lock.hcl; done
