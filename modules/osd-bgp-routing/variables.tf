variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region (e.g., us-central1)"
}

variable "cluster_name" {
  type        = string
  description = "Name of the OSD cluster (used for resource naming)"
}

variable "vpc_id" {
  type        = string
  description = "VPC network self-link"
}

variable "subnet_id" {
  type        = string
  description = "Worker subnet: full self_link URL or projects/PROJECT/regions/REGION/subnetworks/NAME."
}

variable "cudn_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "CUDN prefix advertised via BGP and used in worker-subnet-to-CUDN firewall"
}

variable "worker_subnet_to_cudn_firewall_mode" {
  type        = string
  default     = "e2etest"
  description = <<-EOT
    Ingress firewall for traffic from the worker subnet to CUDN CIDR.
    - all: allow all protocols (broadest; closer to former PoC default).
    - e2etest: ICMP plus TCP/80 only (enough for make *-e2e: ping + icanhazip HTTP on pods).
    - none: do not create this rule (supply your own firewall policy).
  EOT

  validation {
    condition     = contains(["all", "e2etest", "none"], var.worker_subnet_to_cudn_firewall_mode)
    error_message = "worker_subnet_to_cudn_firewall_mode must be all, e2etest, or none."
  }
}

variable "routing_worker_target_tags" {
  type        = list(string)
  default     = []
  description = <<-EOT
    If non-empty, restrict worker-subnet→CUDN and BGP (tcp/179) firewall rules to instances with these
    network tags (GCP best practice for router appliances). OSD workers must be configured with matching
    tags (e.g. MachineSet / instance template). Empty list = rule applies to all instances in the VPC
    that match source/destination ranges (reference / lab default).
  EOT
}

variable "router_instances" {
  type = list(object({
    name       = string
    self_link  = string
    zone       = string
    ip_address = string
  }))
  description = "Worker instances as router appliances: GCE name, self_link, zone, and primary internal IP. Each instance gets 2 BGP peers (one per Cloud Router interface)."
}

variable "cloud_router_asn" {
  type        = number
  default     = 64512
  description = "BGP ASN for Cloud Router (RFC 6996 private ASN; required by Terraform provider validation)."
}

variable "frr_asn" {
  type        = number
  default     = 65003
  description = "BGP ASN configured on cluster nodes (frr-k8s / FRRConfiguration)."
}

variable "bgp_interface_host_offset" {
  type        = number
  default     = 230
  description = "Host index base for Cloud Router interface IPs in the worker subnet (cidrhost(subnet, offset) and offset+1). Must avoid collision with worker addresses."
}

variable "router_interface_private_ips" {
  type        = list(string)
  default     = null
  description = "Optional explicit private IPs for the 2 Cloud Router interfaces (primary + redundant). Must have exactly 2 elements if set. If null, IPs are derived from subnet CIDR and bgp_interface_host_offset. Each IP must lie within the worker subnetwork primary CIDR."
}

variable "reserve_cloud_router_interface_ips" {
  type        = bool
  default     = true
  description = <<-EOT
    When true (recommended), create google_compute_address (INTERNAL, GCE_ENDPOINT) for each Cloud Router interface IP
    so other GCE resources cannot claim those addresses. Set false for brownfield stacks where interfaces already exist
    without reservations—then enable reservations in a planned maintenance window if desired.
  EOT
}

variable "enable_echo_client_vm" {
  type        = bool
  default     = false
  description = "Create an optional VM running icanhazip-clone for CUDN-to-VM direct IP verification."
}

variable "echo_client_vm_port" {
  type        = number
  default     = 8080
  description = "Host port for the echo VM HTTP listener (maps to container port 80)."
}

variable "echo_client_vm_zone" {
  type        = string
  default     = null
  description = "Zone for the echo VM. If null, uses the first zone from router_instances."
}

variable "echo_client_vm_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Machine type for the echo VM."
}

variable "ncc_spoke_site_to_site_data_transfer" {
  type        = bool
  default     = false
  description = "site_to_site_data_transfer on the Router Appliance spoke (see GCP NCC docs for your use case)."
}
