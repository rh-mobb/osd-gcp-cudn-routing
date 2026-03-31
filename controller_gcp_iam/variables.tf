variable "ocm_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "OCM offline token (optional; use OSDGOOGLE_TOKEN env var instead)"
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID (must match wif_config and cluster_bgp_routing)"
}

variable "cluster_name" {
  type        = string
  description = "OSD cluster name (must match wif_config / cluster_bgp_routing; WIF display name defaults to \"<cluster_name>-wif\")"
}

variable "openshift_version" {
  type        = string
  default     = "4.21.3"
  description = "OpenShift version (x.y.z) — must match osdgoogle provider"
}

variable "wif_config_display_name" {
  type        = string
  default     = null
  nullable    = true
  description = "Override WIF config display_name for data.osdgoogle_wif_config (default: \"<cluster_name>-wif\")"
}

variable "wif_kubernetes_token_audience" {
  type        = string
  default     = "openshift"
  description = <<-EOT
    `aud` claim for the projected ServiceAccount JWT; must match an entry in the workload identity
    OIDC provider's allowedAudiences (see `gcloud iam workload-identity-pools providers describe`).
    OpenShift Dedicated GCP WIF from OCM typically uses the literal string "openshift", not the
    `//iam.googleapis.com/...` URL.
  EOT
}

variable "kubernetes_namespace" {
  type        = string
  default     = "bgp-routing-system"
  description = "Namespace of the controller ServiceAccount (must match deploy/rbac.yaml)"
}

variable "kubernetes_service_account_name" {
  type        = string
  default     = "bgp-routing-controller"
  description = "Kubernetes ServiceAccount name (must match deploy/rbac.yaml)"
}

variable "service_account_id" {
  type        = string
  default     = "bgp-routing-controller"
  description = "GCP service account_id (short name)"
}

variable "custom_role_id" {
  type        = string
  default     = "bgp_routing_controller"
  description = "Custom role ID within the GCP project"
}
