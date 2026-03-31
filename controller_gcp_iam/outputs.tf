output "gcp_project_id" {
  value       = var.gcp_project_id
  description = "GCP project ID (for gcloud --project when tuning WIF OIDC allowed audiences)"
}

output "gcp_service_account_email" {
  value       = module.controller_iam.gcp_service_account_email
  description = "GCP SA email for the controller (Workload Identity impersonation)"
}

output "workload_identity_provider_resource_name" {
  value       = module.controller_iam.workload_identity_provider_resource_name
  description = "Provider resource path for gcloud workload-identity-pools create-cred-config"
}

output "wif_kubernetes_token_audience" {
  value       = var.wif_kubernetes_token_audience
  description = "Projected SA token audience (must match OIDC provider allowedAudiences; substitute into deploy/deployment.yaml)"
}

output "custom_role_id" {
  value       = module.controller_iam.custom_role_id
  description = "Full custom role resource name"
}

output "wif_config_display_name" {
  value       = local.wif_display_name
  description = "WIF config display name used for the data source"
}

output "workload_identity_principal_member" {
  value       = module.controller_iam.workload_identity_principal_member
  description = "principal://…/subject/system:serviceaccount:… bound with workloadIdentityUser (debugging)"
}
