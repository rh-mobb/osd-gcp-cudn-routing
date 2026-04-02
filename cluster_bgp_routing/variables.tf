variable "ocm_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "OCM offline token (optional; use OSDGOOGLE_TOKEN env var instead)"
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID for the cluster"
}

variable "cluster_name" {
  type        = string
  default     = "my-bgp-cluster"
  description = "Name of the cluster (must match terraform/wif_config)"
}

variable "openshift_version" {
  type        = string
  default     = "4.21.3"
  description = "OpenShift version (x.y.z)"
}

variable "admin_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Cluster admin password (optional; auto-generated if omitted)"
}

variable "gcp_region" {
  type        = string
  default     = "us-central1"
  description = "GCP region"
}

variable "compute_machine_type" {
  type        = string
  default     = "n2-standard-4"
  description = "GCP machine type for the default OSD worker pool (OCM catalog; matches osd-cluster default intent — e.g. n2-standard-4)."
}

variable "compute_nodes" {
  type        = number
  default     = 6
  description = "Number of worker nodes in the default machine pool"
}

variable "availability_zones" {
  type        = list(string)
  default     = null
  nullable    = true
  description = "GCP zones for the default worker pool. If null, uses the first three zones in gcp_region (multi-AZ). Set to a one-element list for single-AZ."

  validation {
    condition     = var.availability_zones == null || length(var.availability_zones) > 0
    error_message = "availability_zones must be null (use region default) or a non-empty list of zone names."
  }
}

variable "cudn_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "CUDN CIDR advertised via BGP to the VPC"
}

variable "worker_subnet_to_cudn_firewall_mode" {
  type        = string
  default     = "all"
  description = "Worker subnet → CUDN firewall: all (default) | e2etest | none. Passed to osd-bgp-routing."

  validation {
    condition     = contains(["all", "e2etest", "none"], var.worker_subnet_to_cudn_firewall_mode)
    error_message = "worker_subnet_to_cudn_firewall_mode must be all, e2etest, or none."
  }
}

variable "routing_worker_target_tags" {
  type        = list(string)
  default     = []
  description = "Optional network tags to scope worker→CUDN and BGP:179 firewalls to router workers. Empty = subnet-wide (lab default)."
}

variable "enable_bgp_routing" {
  type        = bool
  default     = false
  description = "Enable BGP/NCC/Cloud Router static infrastructure (hub, router, interfaces, firewalls). The controller manages the dynamic resources (spoke, peers, FRRConfiguration)."
}

variable "cloud_router_asn" {
  type        = number
  default     = 64512
  description = "BGP ASN on Cloud Router (RFC 6996 private ASN)."
}

variable "frr_asn" {
  type        = number
  default     = 65003
  description = "BGP ASN on cluster nodes (FRRConfiguration); must match Cloud Router peer_asn."
}

variable "bgp_interface_host_offset" {
  type        = number
  default     = 230
  description = "Host index base for Cloud Router interface IPs (see modules/osd-bgp-routing)."
}

variable "router_interface_private_ips" {
  type        = list(string)
  default     = null
  description = "Optional explicit Cloud Router interface IPs (exactly 2 elements: primary + redundant). If null, derived from subnet CIDR + bgp_interface_host_offset. Must fall within the worker subnetwork primary CIDR."
}

variable "reserve_cloud_router_interface_ips" {
  type        = bool
  default     = true
  description = "Reserve Cloud Router interface IPs with google_compute_address (recommended). Set false for brownfield upgrades if plan fails until interfaces are recreated; see modules/osd-bgp-routing README."
}

variable "enable_echo_client_vm" {
  type        = bool
  default     = false
  description = "Optional echo VM for CUDN checks. Requires enable_bgp_routing=true."
}

variable "echo_client_vm_zone" {
  type        = string
  default     = null
  description = "Zone for the echo VM. If null, uses the first entry in the resolved worker-pool zones (see availability_zones)."
}

variable "echo_client_vm_port" {
  type        = number
  default     = 8080
  description = "Host port for the echo VM HTTP listener."
}

variable "echo_client_vm_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Machine type for the echo VM."
}

variable "enable_psc" {
  type        = bool
  default     = false
  description = "Enable PSC for private cluster (requires OpenShift 4.17+)"
}

variable "ncc_spoke_site_to_site_data_transfer" {
  type        = bool
  default     = false
  description = "NCC router appliance spoke site_to_site_data_transfer flag (passed to controller via output)."
}
