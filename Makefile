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
OPERATOR_DIR := operator
IAM_DIR := controller_gcp_iam
MODULES := $(sort $(notdir $(wildcard modules/*/)))

# Optional extra terraform CLI args (e.g. TF_VARS="-var-file=custom.tfvars").
TF_VARS :=
EXTRA_TF_VARS ?=

.PHONY: help login
help:
	@echo "OSD GCP CUDN routing — BGP reference stack (Terraform + Operator)"
	@echo ""
	@echo "  (ILB reference stack and legacy controllers live under archive/ — see archive/README.md.)"
	@echo ""
	@echo "  login         oc login using cluster_bgp_routing/ Terraform outputs (api_url, admin creds); retries on failure"
	@echo "  create        bgp.run + bgp.deploy-operator (GHCR image); prints oc get nodes … + make bgp.e2e reminder (does not run e2e)"
	@echo "  dev           bgp.run + in-cluster operator build; same reminder as create (does not run e2e)"
	@echo "  destroy       bgp.destroy-operator + bgp.teardown (full stack teardown; all terraform destroy steps use -auto-approve)"
	@echo ""
	@echo "  bgp.run       full deploy: WIF, cluster apply (hub VPC + spoke VPC + peering + default route + BGP/NCC/echo VM), oc login, configure-routing.sh"
	@echo "  bgp.teardown  terraform destroy $(CLUSTER_BGP_DIR)/ then $(WIF_DIR)/ (-auto-approve); run bgp.destroy-operator first if you used the in-cluster operator"
	@echo "  bgp.e2e       CUDN pod ↔ echo VM checks ($(CLUSTER_BGP_DIR)/; requires oc + gcloud logged in)"
	@echo "  networking.validate  CUDN e2e + optional virt e2e + optional internet probes (scripts/networking-validation-test.sh)"
	@echo "  bgp.phase1-baseline  fix-bgp-ra Phase 1: router nodes, RA nodeSelector, FRR CRs, debug-gcp-bgp (oc + terraform + gcloud)"
	@echo "  bgp.deploy-operator    After bgp.run: IAM + WIF Secret + CRDs + RBAC + BGPRoutingConfig + operator build/rollout"
	@echo "  bgp.destroy-operator   Delete BGPRoutingConfig (finalizer cleanup), operator resources, CRDs, then IAM terraform destroy"
	@echo ""
	@echo "  virt.deploy            Hyperdisk pool + StorageClass + VolumeSnapshotClass, then OpenShift Virtualization (CNV)"
	@echo "  virt.destroy-storage   All KubeVirt VMs first, then PVCs/snapshots/CDI, SC/VSC + standard-csi default; GCP disks in pool + Hyperdisk pool (virt_storage_zone; fallback: all worker zones)"
	@echo "  virt.e2e               Deploy virt-e2e VMs + virtctl console/ssh hints (default); add --run-tests for full e2e (see scripts/README.md)"
	@echo "  virt.ssh.bridge        Interactive SSH to VIRT_E2E_VM_NAME_BRIDGE (default virt-e2e-bridge) via netshoot-cudn"
	@echo "  virt.ssh.masq          Interactive SSH to VIRT_E2E_VM_NAME_MASQ (default virt-e2e-masq) via netshoot-cudn"
	@echo ""
	@echo "  operator.build         Compile the operator binary (go build under $(OPERATOR_DIR)/)"
	@echo "  operator.test          go test ./... under $(OPERATOR_DIR)/"
	@echo "  operator.generate      Run controller-gen (deepcopy, etc.)"
	@echo "  operator.manifests     Generate CRD, RBAC, and webhook manifests"
	@echo "  operator.docker-build  Build the operator container image (podman/docker)"
	@echo ""
	@echo "  iam.init      terraform init -upgrade in $(IAM_DIR)/"
	@echo "  iam.plan      terraform plan in $(IAM_DIR)/"
	@echo "  iam.apply     terraform apply in $(IAM_DIR)/"
	@echo "  iam.destroy   terraform destroy -auto-approve in $(IAM_DIR)/"
	@echo "  iam.credentials  Generate credential-config.json (+ optional Secret via env)"
	@echo ""
	@echo "  wif.init      terraform init -upgrade in $(WIF_DIR)/"
	@echo "  wif.plan      terraform plan in $(WIF_DIR)/"
	@echo "  wif.apply     terraform apply in $(WIF_DIR)/ (run before cluster apply)"
	@echo "  wif.destroy   terraform destroy -auto-approve in $(WIF_DIR)/ (after cluster destroy)"
	@echo "  wif.undelete-soft-deleted-roles  Undelete soft-deleted WIF custom roles (reads wif_config/ Terraform + gcloud; optional WIF_UNDELETE_ARGS; see scripts/README.md)"
	@echo ""
	@echo "  bgp.init      terraform init -upgrade in $(CLUSTER_BGP_DIR)/"
	@echo "  bgp.plan      terraform plan in $(CLUSTER_BGP_DIR)/"
	@echo "  bgp.apply     terraform apply in $(CLUSTER_BGP_DIR)/"
	@echo "  cluster.destroy  terraform destroy -auto-approve in $(CLUSTER_BGP_DIR)/ only (expert; not WIF / IAM)"
	@echo "  fmt           terraform fmt -recursive"
	@echo "  validate      terraform validate ($(WIF_DIR)/, modules, $(CLUSTER_BGP_DIR)/, $(IAM_DIR)/)"
	@echo "  clean         remove .terraform/ and lock files under repo"
	@echo ""
	@echo "WIF uses osd-wif-config from terraform-provider-osd-google (Git module source)."
	@echo "Provider rh-mobb/osd-google ~> 0.1.3 from Terraform Registry (no dev_overrides)."
	@echo "See README.md for prerequisites and workflow; scripts/README.md for bgp.run env vars."
	@echo "Naming: stack.action with dots; multi-word segments use hyphens (e.g. iam.init)."

login:
	@bash "$(CURDIR)/scripts/oc-login.sh"

CREATE_OPERATOR_IMAGE ?= ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-routing-operator:latest
BGP_OPERATOR_NAMESPACE ?= bgp-routing-system

.PHONY: create dev destroy post-operator-deploy-msg bgp.run bgp.teardown bgp.e2e networking.validate bgp.phase1-baseline bgp.deploy-operator bgp.destroy-operator
post-operator-deploy-msg:
	@echo ""
	@echo "=== Operator deployed ($(BGP_OPERATOR_NAMESPACE)/deployment/bgp-routing-operator) ==="
	@echo "Watch nodes with the BGP router label until every listed node has STATUS Ready (expected worker count), then run connectivity checks:"
	@echo "  watch 'oc get nodes -l routing.osd.redhat.com/bgp-router='"
	@echo "  (Ctrl+C to stop watch.)"
	@echo "  make bgp.e2e"
	@echo "  make networking.validate   # CUDN e2e + optional virt e2e (see docs/networking-validation-test-plan.md)"

create:
	@$(MAKE) bgp.run
	@$(MAKE) bgp.deploy-operator BGP_OPERATOR_PREBUILT_IMAGE="$(CREATE_OPERATOR_IMAGE)"
	@$(MAKE) post-operator-deploy-msg

dev:
	@$(MAKE) bgp.run
	@$(MAKE) bgp.deploy-operator
	@$(MAKE) post-operator-deploy-msg

destroy:
	@echo "=== make destroy: full stack teardown ==="
	@echo ">>> Phase 1/2: bgp.destroy-operator (in-cluster cleanup + $(IAM_DIR)/)"
	@$(MAKE) bgp.destroy-operator
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

networking.validate:
	@bash "$(CURDIR)/scripts/networking-validation-test.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

bgp.phase1-baseline:
	@bash "$(CURDIR)/scripts/bgp-phase1-baseline.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

bgp.deploy-operator:
	@bash "$(CURDIR)/scripts/bgp-deploy-operator-incluster.sh" $(TF_VARS) $(EXTRA_TF_VARS)

bgp.destroy-operator:
	@echo "=== bgp.destroy-operator ==="
	@echo ">>> Step 1/4: Delete BGPRoutingConfig (triggers finalizer cleanup)"
	-@oc delete bgproutingconfig cluster --ignore-not-found=true --timeout=120s 2>/dev/null || true
	@echo ""
	@echo ">>> Step 2/4: Delete operator Deployment, RBAC, namespace resources"
	-@oc delete -f "$(CURDIR)/$(OPERATOR_DIR)/deploy/deployment.yaml" --ignore-not-found=true 2>/dev/null || true
	-@oc delete -f "$(CURDIR)/$(OPERATOR_DIR)/deploy/rbac.yaml" --ignore-not-found=true 2>/dev/null || true
	@echo ""
	@echo ">>> Step 3/4: Delete CRDs"
	-@oc delete -f "$(CURDIR)/$(OPERATOR_DIR)/config/crd/bases/" --ignore-not-found=true 2>/dev/null || true
	@echo ""
	@echo ">>> Step 4/4: iam.destroy (Terraform in $(IAM_DIR)/)"
	@$(MAKE) iam.destroy
	@echo ""
	@echo "=== bgp.destroy-operator: finished ==="

# ---- OpenShift Virtualization + RWX storage ----
.PHONY: virt.deploy virt.destroy-storage virt.e2e virt.ssh.bridge virt.ssh.masq
virt.deploy:
	@bash "$(CURDIR)/scripts/deploy-openshift-virt.sh"

virt.destroy-storage:
	@bash "$(CURDIR)/scripts/destroy-openshift-virt-storage.sh"

virt.e2e:
	@bash "$(CURDIR)/scripts/e2e-virt-live-migration.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)"

# Interactive SSH to virt-e2e guests (netshoot jump). Override: CUDN_NAMESPACE, VIRT_E2E_VM_NAME_* .
virt.ssh.bridge:
	@bash "$(CURDIR)/scripts/virt-ssh.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)" \
		-n "$(or $(CUDN_NAMESPACE),cudn1)" "$(or $(VIRT_E2E_VM_NAME_BRIDGE),virt-e2e-bridge)"

virt.ssh.masq:
	@bash "$(CURDIR)/scripts/virt-ssh.sh" -C "$(CURDIR)/$(CLUSTER_BGP_DIR)" \
		-n "$(or $(CUDN_NAMESPACE),cudn1)" "$(or $(VIRT_E2E_VM_NAME_MASQ),virt-e2e-masq)"

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

.PHONY: bgp.init bgp.plan bgp.apply cluster.destroy
bgp.init:
	@cd $(CLUSTER_BGP_DIR) && terraform init -upgrade

bgp.plan: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

bgp.apply: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

cluster.destroy: bgp.init
	@cd $(CLUSTER_BGP_DIR) && terraform destroy -auto-approve $(TF_VARS) $(EXTRA_TF_VARS)

# ---- Operator (CRD-based) targets ----
.PHONY: operator.build operator.test operator.generate operator.manifests operator.docker-build
operator.build:
	@$(MAKE) -C $(OPERATOR_DIR) build

operator.test:
	@$(MAKE) -C $(OPERATOR_DIR) test

operator.generate:
	@$(MAKE) -C $(OPERATOR_DIR) generate

operator.manifests:
	@$(MAKE) -C $(OPERATOR_DIR) manifests

OPERATOR_IMG ?= ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-routing-operator:latest
operator.docker-build:
	@$(MAKE) -C $(OPERATOR_DIR) docker-build IMG=$(OPERATOR_IMG)

# ---- IAM (GCP SA + WIF for the operator) ----
.PHONY: iam.init iam.plan iam.apply iam.destroy iam.credentials
iam.init:
	@cd $(IAM_DIR) && terraform init -upgrade

iam.plan: iam.init
	@cd $(IAM_DIR) && terraform plan $(TF_VARS) $(EXTRA_TF_VARS)

iam.apply: iam.init
	@cd $(IAM_DIR) && terraform apply $(TF_VARS) $(EXTRA_TF_VARS)

iam.destroy: iam.init
	@echo ">>> iam.destroy: terraform destroy in $(IAM_DIR)/"
	@cd $(IAM_DIR) && terraform destroy -auto-approve $(TF_VARS) $(EXTRA_TF_VARS)

iam.credentials:
	@CONTROLLER_GCP_IAM_DIR="$(CURDIR)/$(IAM_DIR)" \
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
	@echo "Validating $(IAM_DIR)..."
	@cd $(IAM_DIR) && terraform init -backend=false -input=false -upgrade && terraform validate

.PHONY: clean
clean:
	@rm -rf $(WIF_DIR)/.terraform $(WIF_DIR)/.terraform.lock.hcl
	@rm -rf $(ARCHIVE_ILB_DIR)/.terraform $(ARCHIVE_ILB_DIR)/.terraform.lock.hcl
	@rm -rf $(CLUSTER_BGP_DIR)/.terraform $(CLUSTER_BGP_DIR)/.terraform.lock.hcl
	@rm -rf $(IAM_DIR)/.terraform $(IAM_DIR)/.terraform.lock.hcl
	@for mod in $(MODULES); do rm -rf modules/$$mod/.terraform modules/$$mod/.terraform.lock.hcl; done
