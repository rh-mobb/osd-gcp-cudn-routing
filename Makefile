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
CONTROLLER_DIR := controller/python
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
	@echo "  bgp.run       full deploy: WIF, cluster single apply (BGP+NCC+echo VM), oc login, cluster_bgp_routing configure-routing.sh"
	@echo "  bgp.teardown  terraform destroy $(CLUSTER_BGP_DIR)/ then $(WIF_DIR)/ (-auto-approve); run controller.cleanup first if you used the controller"
	@echo "  bgp.e2e       CUDN pod ↔ echo VM checks ($(CLUSTER_BGP_DIR)/; requires oc + gcloud logged in)"
	@echo "                strict Phase 3: CUDN_E2E_POD_AVOID_BGP_ROUTERS=1 make bgp.e2e (pods not on bgp-router nodes)"
	@echo "  bgp.phase1-baseline  fix-bgp-ra Phase 1: router nodes, RA nodeSelector, FRR CRs, debug-gcp-bgp (oc + terraform + gcloud)"
	@echo "  bgp.deploy-controller  After bgp.run: IAM + WIF Secret + ConfigMap from TF + in-cluster controller"
	@echo ""
	@echo "  controller.venv      Create Python venv for the BGP routing controller"
	@echo "  controller.run       One-shot reconciliation (reads terraform output)"
	@echo "  controller.watch     Run the long-lived operator (kopf event loop)"
	@echo "  controller.cleanup   Delete controller Deployment (if any), peers, spoke, FRR, router labels"
	@echo "  controller.build     Build the controller container image (podman, local)"
	@echo "  controller.deploy-openshift  Apply deploy/ + BuildConfig binary build + rollout"
	@echo "  controller.gcp-iam.* Terraform in $(CONTROLLER_GCP_IAM_DIR)/ (GCP SA + WIF bind; after WIF + cluster)"
	@echo "  controller.gcp-credentials  Generate credential-config.json (+ optional Secret via env)"
	@echo ""
	@echo "  wif.init      terraform init -upgrade in $(WIF_DIR)/"
	@echo "  wif.plan      terraform plan in $(WIF_DIR)/"
	@echo "  wif.apply     terraform apply in $(WIF_DIR)/ (run before cluster apply)"
	@echo "  wif.destroy   terraform destroy in $(WIF_DIR)/ (after cluster destroy)"
	@echo ""
	@echo "  init          terraform init -upgrade in $(CLUSTER_BGP_DIR)/ (same root as bgp.init)"
	@echo "  plan          terraform plan in $(CLUSTER_BGP_DIR)/"
	@echo "  apply         terraform apply in $(CLUSTER_BGP_DIR)/"
	@echo "  destroy       terraform destroy in $(CLUSTER_BGP_DIR)/"
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

.PHONY: bgp.run bgp.teardown bgp.e2e bgp.phase1-baseline bgp.deploy-controller
bgp.run:
	@bash "$(CURDIR)/scripts/bgp-apply.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp.teardown:
	@bash "$(CURDIR)/scripts/bgp-destroy.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp.e2e:
	@bash "$(CURDIR)/scripts/e2e-cudn-connectivity.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)" --avoid-bgp-router

bgp.phase1-baseline:
	@bash "$(CURDIR)/scripts/bgp-phase1-baseline.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

bgp.deploy-controller:
	@bash "$(CURDIR)/scripts/bgp-deploy-controller-incluster.sh" $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: wif.init wif.plan wif.apply wif.destroy
wif.init:
	@cd $(WIF_DIR) && terraform init -upgrade

wif.plan: wif.init
	@cd $(WIF_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

wif.apply: wif.init
	@cd $(WIF_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

wif.destroy: wif.init
	@cd $(WIF_DIR) && terraform destroy $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: init
init:
	@cd $(CLUSTER_BGP_DIR) && terraform init -upgrade

.PHONY: plan
plan: init
	@cd $(CLUSTER_BGP_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: apply
apply: init
	@cd $(CLUSTER_BGP_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: destroy
destroy: init
	@cd $(CLUSTER_BGP_DIR) && terraform destroy $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: bgp.init bgp.plan bgp.apply
bgp.init:
	@cd $(CLUSTER_BGP_DIR) && terraform init -upgrade

bgp.plan: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

bgp.apply: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: controller.venv controller.run controller.watch controller.cleanup controller.build controller.deploy-openshift
controller.venv:
	@$(MAKE) -C $(CONTROLLER_DIR) venv

controller.run:
	@$(MAKE) -C $(CONTROLLER_DIR) run

controller.watch:
	@$(MAKE) -C $(CONTROLLER_DIR) watch

controller.cleanup:
	@$(MAKE) -C $(CONTROLLER_DIR) cleanup

controller.build:
	@$(MAKE) -C $(CONTROLLER_DIR) build

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
	@cd $(CONTROLLER_GCP_IAM_DIR) && terraform destroy $(TF_VARS) $(EXTRA_TF_VARS)

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
