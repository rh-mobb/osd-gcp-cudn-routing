# OSD cluster with BGP-based CUDN routing (NCC + Cloud Router)
#
# Prerequisites:
#   - OCM token (OSDGOOGLE_TOKEN or ocm_token variable)
#   - GCP project with WIF prerequisites (see OSD documentation)
#   - Application Default Credentials (gcloud auth application-default login)
#   - jq (for discover-workers.sh and configure-routing.sh)
#
# Usage:
#   1. terraform init && terraform apply  (creates cluster + VPC)
#   2. Wait for workers, then terraform apply again (discovers instances, creates BGP/NCC)
#   3. oc login, then run scripts/configure-routing.sh

terraform {
  required_providers {
    osdgoogle = {
      source  = "registry.terraform.io/rh-mobb/osd-google"
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
