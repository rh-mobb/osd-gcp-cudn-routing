variable "project_id" {
  type        = string
  description = "GCP project ID where the service account and custom role are created"
}

variable "project_number_for_wif_principal" {
  type        = string
  description = "GCP project number used in WIF principal and provider resource paths (use federated project number from osdgoogle_wif_config when set)"
}

variable "workload_identity_pool_id" {
  type        = string
  description = "Workload identity pool ID from osdgoogle_wif_config (short ID, not full resource name)"
}

variable "workload_identity_provider_id" {
  type        = string
  description = "Workload identity OIDC provider ID from osdgoogle_wif_config"
}

variable "kubernetes_namespace" {
  type        = string
  description = "OpenShift namespace of the controller ServiceAccount"
  default     = "bgp-routing-system"
}

variable "kubernetes_service_account_name" {
  type        = string
  description = "Name of the Kubernetes ServiceAccount that impersonates the GCP SA"
  default     = "bgp-routing-controller"
}

variable "service_account_id" {
  type        = string
  description = "account_id for google_service_account (6-30 chars, [a-z0-9-])"
  default     = "bgp-routing-controller"
}

variable "service_account_display_name" {
  type        = string
  description = "Display name for the GCP service account"
  default     = "BGP Routing Controller"
}

variable "custom_role_id" {
  type        = string
  description = "Role ID for google_project_iam_custom_role (unique within the project)"
  default     = "bgp_routing_controller"
}

variable "custom_role_title" {
  type        = string
  default     = "BGP Routing Controller"
  description = "Human-readable title for the custom IAM role"
}

variable "custom_role_permissions" {
  type        = list(string)
  description = "Permission set for the controller (least privilege for NCC spoke, Cloud Router peers, GCE instance updates)"
  default = [
    "compute.instances.get",
    "compute.instances.list",
    "compute.instances.update",
    "compute.networks.get",
    "compute.networks.updatePolicy",
    "compute.zones.list",
    "networkconnectivity.operations.get",
    "networkconnectivity.spokes.create",
    "networkconnectivity.spokes.delete",
    "networkconnectivity.spokes.get",
    "networkconnectivity.spokes.list",
    "networkconnectivity.spokes.update",
    "compute.routers.get",
    "compute.routers.update",
  ]
}
