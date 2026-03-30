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

CLUSTER_DIR := cluster_ilb_routing
CLUSTER_BGP_DIR := cluster_bgp_routing
WIF_DIR := wif_config
CONTROLLER_DIR := controller/python
MODULES := $(sort $(notdir $(wildcard modules/*/)))

# Optional extra terraform CLI args (e.g. TF_VARS="-var-file=custom.tfvars").
TF_VARS :=
EXTRA_TF_VARS ?=

.PHONY: help
help:
	@echo "OSD GCP CUDN routing (Terraform)"
	@echo ""
	@echo "  ilb-apply     full deploy: WIF, cluster pass1, wait workers, pass2 ILB+echo VM, oc login, configure-routing.sh"
	@echo "  ilb-destroy   terraform destroy $(CLUSTER_DIR)/ then $(WIF_DIR)/ (-auto-approve)"
	@echo "  ilb-e2e       CUDN pod ↔ echo VM checks ($(CLUSTER_DIR)/; requires oc + gcloud logged in)"
	@echo "  bgp-apply     full deploy: WIF, cluster pass1, wait workers, pass2 BGP+NCC+echo VM, oc login, cluster_bgp_routing configure-routing.sh"
	@echo "  bgp-destroy   terraform destroy $(CLUSTER_BGP_DIR)/ then $(WIF_DIR)/ (-auto-approve); run controller.cleanup first if you used the controller"
	@echo "  bgp-e2e       CUDN pod ↔ echo VM checks ($(CLUSTER_BGP_DIR)/; requires oc + gcloud logged in)"
	@echo ""
	@echo "  controller.venv      Create Python venv for the BGP routing controller"
	@echo "  controller.run       One-shot reconciliation (reads terraform output)"
	@echo "  controller.watch     Run the long-lived operator (kopf event loop)"
	@echo "  controller.cleanup   Delete all controller-managed resources (peers, spoke, FRR)"
	@echo "  controller.build     Build the controller container image (podman, local)"
	@echo "  controller.deploy-openshift  Apply deploy/ + BuildConfig binary build + rollout"
	@echo ""
	@echo "  wif.init      terraform init -upgrade in $(WIF_DIR)/"
	@echo "  wif.plan      terraform plan in $(WIF_DIR)/"
	@echo "  wif.apply     terraform apply in $(WIF_DIR)/ (run before cluster apply)"
	@echo "  wif.destroy   terraform destroy in $(WIF_DIR)/ (after cluster destroy)"
	@echo ""
	@echo "  init          terraform init -upgrade in $(CLUSTER_DIR)/ (ILB stack)"
	@echo "  plan          terraform plan in $(CLUSTER_DIR)/"
	@echo "  apply         terraform apply in $(CLUSTER_DIR)/"
	@echo "  destroy       terraform destroy in $(CLUSTER_DIR)/"
	@echo "  bgp.init      terraform init -upgrade in $(CLUSTER_BGP_DIR)/"
	@echo "  bgp.plan      terraform plan in $(CLUSTER_BGP_DIR)/"
	@echo "  bgp.apply     terraform apply in $(CLUSTER_BGP_DIR)/"
	@echo "  fmt           terraform fmt -recursive"
	@echo "  validate      terraform validate ($(WIF_DIR)/, modules, $(CLUSTER_DIR)/, $(CLUSTER_BGP_DIR)/)"
	@echo "  clean         remove .terraform/ and lock files under repo"
	@echo ""
	@echo "WIF uses osd-wif-config from terraform-provider-osd-google (Git module source)."
	@echo "Provider rh-mobb/osd-google ~> 0.1.3 from Terraform Registry (no dev_overrides)."
	@echo "See README.md for prerequisites and workflow; scripts/README.md for ilb-apply / bgp-apply env vars."

.PHONY: ilb-apply ilb-destroy
ilb-apply:
	@bash "$(CURDIR)/scripts/ilb-apply.sh" $(TF_VARS) $(EXTRA_TF_VARS)

ilb-destroy:
	@bash "$(CURDIR)/scripts/ilb-destroy.sh" $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: ilb-e2e bgp-e2e
ilb-e2e:
	@bash "$(CURDIR)/scripts/e2e-cudn-connectivity.sh" -C "$(CURDIR)/$(CLUSTER_DIR)"

bgp-e2e:
	@bash "$(CURDIR)/scripts/e2e-cudn-connectivity.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

.PHONY: bgp-apply bgp-destroy
bgp-apply:
	@bash "$(CURDIR)/scripts/bgp-apply.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp-destroy:
	@bash "$(CURDIR)/scripts/bgp-destroy.sh" $(TF_VARS) $(EXTRA_TF_VARS)

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
	@cd $(CLUSTER_DIR) && terraform init -upgrade

.PHONY: plan
plan: init
	@cd $(CLUSTER_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: apply
apply: init
	@cd $(CLUSTER_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

.PHONY: destroy
destroy: init
	@cd $(CLUSTER_DIR) && terraform destroy $(TF_VARS) $(EXTRA_TF_VARS)

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
	@echo "Validating $(CLUSTER_DIR)..."
	@cd $(CLUSTER_DIR) && terraform init -backend=false -input=false -upgrade && terraform validate
	@echo "Validating $(CLUSTER_BGP_DIR)..."
	@cd $(CLUSTER_BGP_DIR) && terraform init -backend=false -input=false -upgrade && terraform validate

.PHONY: clean
clean:
	@rm -rf $(WIF_DIR)/.terraform $(WIF_DIR)/.terraform.lock.hcl
	@rm -rf $(CLUSTER_DIR)/.terraform $(CLUSTER_DIR)/.terraform.lock.hcl
	@rm -rf $(CLUSTER_BGP_DIR)/.terraform $(CLUSTER_BGP_DIR)/.terraform.lock.hcl
	@for mod in $(MODULES); do rm -rf modules/$$mod/.terraform modules/$$mod/.terraform.lock.hcl; done
