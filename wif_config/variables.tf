variable "ocm_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "OCM offline token (optional; use OSDGOOGLE_TOKEN env var instead)"
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID for WIF resources"
}

variable "cluster_name" {
  type        = string
  default     = "my-wif-cluster"
  description = "Base name for the cluster. WIF display name is derived as cluster_name-wif."
}

variable "openshift_version" {
  type        = string
  default     = "4.21.3"
  description = "OpenShift version (x.y.z). WIF roles use x.y only."
}

variable "role_prefix" {
  type        = string
  default     = null
  nullable    = true
  description = "Prefix for custom IAM roles in GCP. When null, uses cluster_name. Hyphens and underscores are stripped."
}
