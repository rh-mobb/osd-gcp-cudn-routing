# WIF config for OSD clusters
#
# Creates the WIF config in OCM. Apply from this directory (or `make wif.apply`
# from the repository root) before `cluster_ilb_routing/`.
#
# Prerequisites:
#   - OCM token (OSDGOOGLE_TOKEN or ocm_token variable)
#   - GCP project with WIF prerequisites (see OSD documentation)
#   - Application Default Credentials (gcloud auth application-default login)

module "wif_config" {
  source = "git::https://github.com/rh-mobb/terraform-provider-osd-google.git//modules/osd-wif-config"

  gcp_project_id    = var.gcp_project_id
  cluster_name      = var.cluster_name
  openshift_version = var.openshift_version
  role_prefix       = var.role_prefix
}
