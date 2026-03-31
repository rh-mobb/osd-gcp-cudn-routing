data "google_project" "project" {
  project_id = var.gcp_project_id
}

locals {
  wif_display_name = coalesce(var.wif_config_display_name, "${var.cluster_name}-wif")
}

data "osdgoogle_wif_config" "wif" {
  display_name = local.wif_display_name
}

locals {
  workload_pool_id       = data.osdgoogle_wif_config.wif.gcp.workload_identity_pool.pool_id
  workload_provider_id   = data.osdgoogle_wif_config.wif.gcp.workload_identity_pool.identity_provider.identity_provider_id
  project_number_for_wif = try(data.osdgoogle_wif_config.wif.gcp.federated_project_number, "") != "" ? data.osdgoogle_wif_config.wif.gcp.federated_project_number : tostring(data.google_project.project.number)
}

module "controller_iam" {
  source = "../modules/osd-bgp-controller-iam"

  project_id                       = var.gcp_project_id
  project_number_for_wif_principal = local.project_number_for_wif
  workload_identity_pool_id        = local.workload_pool_id
  workload_identity_provider_id    = local.workload_provider_id

  kubernetes_namespace            = var.kubernetes_namespace
  kubernetes_service_account_name = var.kubernetes_service_account_name
  service_account_id              = var.service_account_id
  custom_role_id                  = var.custom_role_id
}
