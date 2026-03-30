# OSD cluster with BGP-based CUDN routing (NCC + Cloud Router)
#
# Prerequisites:
#   - OCM token (OSDGOOGLE_TOKEN or ocm_token variable)
#   - GCP project with WIF prerequisites (see OSD documentation)
#   - Application Default Credentials (gcloud auth application-default login)
#
# Usage:
#   1. terraform init && terraform apply -var='enable_bgp_routing=true'
#   2. oc login, then run scripts/configure-routing.sh (one-time setup)
#   3. Deploy the controller (controller/python/) to manage dynamic resources

terraform {
  required_providers {
    osdgoogle = {
      source  = "registry.terraform.io/rh-mobb/osd-google"
      version = "~> 0.1.3"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
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
