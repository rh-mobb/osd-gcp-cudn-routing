# OSD cluster with ILB-based pod network routing
#
# Deploys a bare metal OSD cluster in a BYO VPC, then creates an
# Internal passthrough NLB that routes CUDN traffic directly to
# worker nodes for non-NATted pod/VM IP connectivity.
#
# Prerequisites:
#   - OCM token (OSDGOOGLE_TOKEN or ocm_token variable)
#   - GCP project with WIF prerequisites (see OSD documentation)
#   - Application Default Credentials (gcloud auth application-default login)
#   - jq (for discover-workers.sh and configure-routing.sh worker filtering)
#
# Usage:
#   1. terraform init && terraform apply  (creates cluster + VPC)
#   2. Wait for workers, then terraform apply again (discovers instances, creates ILB)
#   3. oc login, then run scripts/configure-routing.sh

terraform {
  required_providers {
    osdgoogle = {
      source = "registry.terraform.io/rh-mobb/osd-google"
      # Use the registry release; no dev_overrides required.
      version = "~> 0.1.3"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "osdgoogle" {
  token             = var.ocm_token != "" ? var.ocm_token : null
  openshift_version = var.openshift_version
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
