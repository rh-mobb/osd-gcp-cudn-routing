resource "google_project_iam_custom_role" "bgp_routing_controller" {
  project     = var.project_id
  role_id     = var.custom_role_id
  title       = var.custom_role_title
  description = "Least-privilege role for the BGP routing controller (NCC spoke, Cloud Router BGP peers, GCE instance update for canIpForward and nested virtualization, VPC get/updatePolicy for router and instance validation on some topologies)."
  permissions = var.custom_role_permissions
}

resource "google_service_account" "controller" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
}

resource "google_project_iam_member" "controller_custom_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.bgp_routing_controller.id
  member  = "serviceAccount:${google_service_account.controller.email}"
}

# https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes#service-account-impersonation
# Use principal://…/subject/… (google.subject = assertion.sub), not principalSet://…/attribute.sub/…
locals {
  workload_identity_impersonation_member = format(
    "principal://iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s/subject/system:serviceaccount:%s:%s",
    var.project_number_for_wif_principal,
    var.workload_identity_pool_id,
    var.kubernetes_namespace,
    var.kubernetes_service_account_name,
  )
}

resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.controller.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.workload_identity_impersonation_member
}
