variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region"
}

variable "cluster_name" {
  type        = string
  description = "Prefix for resource names"
}

variable "enable_psc" {
  type        = bool
  default     = false
  description = "Create PSC subnet for private clusters"
}

variable "control_plane_subnet_cidr" {
  type        = string
  description = "CIDR for the OpenShift control plane subnet"
}

variable "compute_subnet_cidr" {
  type        = string
  description = "CIDR for the default worker / compute subnet"
}

variable "psc_subnet_cidr" {
  type        = string
  default     = null
  description = "CIDR for Private Service Connect subnet (required when enable_psc is true)"

  validation {
    condition     = !var.enable_psc || var.psc_subnet_cidr != null
    error_message = "When enable_psc is true, psc_subnet_cidr must be set."
  }
}

variable "control_plane_subnet_name" {
  type        = string
  default     = null
  description = "Subnet resource name for control plane (default: <cluster_name>-master-subnet)"
}

variable "compute_subnet_name" {
  type        = string
  default     = null
  description = "Subnet resource name for compute (default: <cluster_name>-worker-subnet)"
}

variable "psc_subnet_name" {
  type        = string
  default     = null
  description = "Subnet resource name for PSC (default: <cluster_name>-psc-subnet)"
}

variable "enable_iap_ssh" {
  type        = bool
  default     = true
  description = "Create a firewall rule allowing IAP TCP tunneling (35.235.240.0/20 → TCP/22) on all instances in the spoke VPC. Enables gcloud compute ssh --tunnel-through-iap for test VMs and debug nodes. Set false in hardened environments."
}

variable "hub_egress_cidr" {
  type        = string
  default     = null
  description = "CIDR of the hub VPC egress subnet (e.g. 10.20.0.0/24). When set, creates a firewall rule allowing all traffic from hub NAT VMs back into the spoke VPC so that CUDN internet egress return traffic is not blocked."
}

variable "enable_cudn_egress_return" {
  type        = bool
  default     = true
  description = <<-EOT
    Allow all inbound traffic (0.0.0.0/0, all protocols) to all instances in the spoke VPC.
    Required for reliable CUDN internet egress: the GCP VPC stateful firewall drops internet
    return packets (src=<public-IP>) on BGP workers that did not originate the outbound connection.
    Enabling this mirrors the AWS rosa-virt-allow-from-ALL-sg pattern and makes internet egress
    100% reliable regardless of Cloud Router ECMP path.
    GCP worker network tags are assigned by the OSD installer and are not under our control,
    so this rule applies VPC-wide rather than to a specific tag subset.
  EOT
}
