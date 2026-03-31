output "gcp_service_account_email" {
  value       = google_service_account.controller.email
  description = "Email of the GCP service account the controller impersonates via WIF"
}

output "gcp_service_account_id" {
  value       = google_service_account.controller.id
  description = "Resource ID of the GCP service account"
}

output "custom_role_id" {
  value       = google_project_iam_custom_role.bgp_routing_controller.id
  description = "Full role resource name (projects/PROJECT/roles/ROLE_ID)"
}

output "workload_identity_provider_resource_name" {
  value = format(
    "projects/%s/locations/global/workloadIdentityPools/%s/providers/%s",
    var.project_number_for_wif_principal,
    var.workload_identity_pool_id,
    var.workload_identity_provider_id,
  )
  description = "Full provider resource name for gcloud iam workload-identity-pools create-cred-config"
}

output "workload_identity_principal_member" {
  value       = local.workload_identity_impersonation_member
  description = "principal://…/subject/system:serviceaccount:… bound with roles/iam.workloadIdentityUser (for troubleshooting)"
}
