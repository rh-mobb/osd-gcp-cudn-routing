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
  default     = "4.21.9"
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
  default     = 3
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

variable "create_baremetal_worker_pool" {
  type        = bool
  default     = true
  description = "When true, provisions an additional osd-cluster machine pool with bare metal workers (see baremetal_* variables). Names 'worker' and 'workers-*' are reserved by OCM; this pool uses baremetal_machine_pool_name."
}

variable "baremetal_machine_pool_name" {
  type        = string
  default     = "baremetal"
  description = "OCM machine pool name for bare metal workers (must not be 'worker' or start with 'workers-')."

  validation {
    condition     = var.baremetal_machine_pool_name != "worker" && !startswith(var.baremetal_machine_pool_name, "workers-")
    error_message = "baremetal_machine_pool_name must not be 'worker' or start with 'workers-' (reserved by OCM)."
  }
}

variable "baremetal_worker_replicas" {
  type        = number
  default     = 2
  description = "Fixed replica count for the bare metal machine pool (autoscaling disabled)."

  validation {
    condition     = var.baremetal_worker_replicas >= 1 && floor(var.baremetal_worker_replicas) == var.baremetal_worker_replicas
    error_message = "baremetal_worker_replicas must be a positive integer."
  }
}

variable "baremetal_instance_type" {
  type        = string
  default     = "c3-standard-192-metal"
  description = "GCP instance type for the bare metal machine pool (OCM catalog; must exist in baremetal_availability_zones)."
}

variable "baremetal_availability_zones" {
  type        = list(string)
  default     = null
  nullable    = true
  description = "Single-AZ (or same-AZ) list for the bare metal pool — bare metal SKUs are zone-specific. If null, uses the first entry in the resolved default worker availability_zones (same as the first default worker zone when zones are sorted by name)."

  validation {
    condition     = var.baremetal_availability_zones == null || length(var.baremetal_availability_zones) > 0
    error_message = "baremetal_availability_zones must be null or a non-empty list."
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

variable "enable_echo_vm" {
  type        = bool
  default     = true
  description = "Create the echo VM (icanhazip-clone) in the spoke worker subnet. Independent of enable_bgp_routing — useful for hub/spoke NAT verification before the cluster is deployed."
}

variable "echo_client_vm_zone" {
  type        = string
  default     = null
  description = "Zone for the echo VM. If null, uses the first resolved worker-pool zone (see availability_zones)."
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
  description = "Enable PSC subnet for private cluster (requires OpenShift 4.17+). Subnet-only; additional PSC globals from osd-vpc may be needed for production private installs — validate against Red Hat PSC requirements."
}

variable "psc_subnet_cidr" {
  type        = string
  default     = null
  nullable    = true
  description = "Private Service Connect subnet CIDR (/29 or larger when enable_psc is true). Typical: 10.0.64.0/29."
}

variable "hub_vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "IPv4 CIDR for the hub VPC (NAT / egress tier). Must not overlap spoke subnets."
}

variable "control_plane_subnet_cidr" {
  type        = string
  default     = "10.0.0.0/19"
  description = "OpenShift control plane subnet CIDR (matches osd-vpc master_cidr scale)."
}

variable "compute_subnet_cidr" {
  type        = string
  default     = "10.0.32.0/19"
  description = "Worker subnet CIDR (matches osd-vpc worker_cidr scale); Cloud Router interface IPs resolve from here."
}

variable "nat_vm_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Machine type for hub NAT gateway VMs."
}

variable "nat_vm_zone_limit" {
  type        = number
  default     = 3
  description = "Place up to this many NAT VMs across the first N availability zones (≤ length of worker zones)."
}

variable "nat_healing_initial_delay_sec" {
  type        = number
  default     = 180
  description = "MIG auto-healing initial delay for NAT VMs."
}

variable "nat_ilb_host_offset" {
  type        = number
  default     = 5
  description = "Host offset within hub egress subnet for reserved internal NLB VIP."
}

variable "nat_health_check_port" {
  type        = number
  default     = 8080
  description = "TCP port for NAT VM health checks (startup script serves HTTP via python)."
}

variable "nat_enable_iap_ssh" {
  type        = bool
  default     = true
  description = "Allow IAP TCP tunneling (35.235.240.0/20 → TCP/22) on NAT VMs. Enables gcloud compute ssh --tunnel-through-iap for debugging. Set false in hardened environments."
}

variable "spoke_enable_iap_ssh" {
  type        = bool
  default     = true
  description = "Allow IAP TCP tunneling (35.235.240.0/20 → TCP/22) on all spoke VPC instances (test VMs, debug nodes). Set false in hardened environments."
}

variable "spoke_enable_cudn_egress_return" {
  type        = bool
  default     = true
  description = "Allow all inbound traffic (0.0.0.0/0, all protocols) to all spoke VPC instances. Required for reliable CUDN internet egress via the hub NAT path: the GCP VPC stateful firewall otherwise drops internet return packets on BGP workers that did not originate the outbound connection. GCP worker network tags are OSD-assigned and not under our control, so the rule is VPC-wide. Set false only in hardened environments that handle this via a separate policy."
}

variable "spoke_default_route_priority" {
  type        = number
  default     = 800
  description = "Priority for spoke 0.0.0.0/0 route to hub NAT ILB (BGP and subnet routes should be more preferred)."
}

check "psc_subnet_when_enabled" {
  assert {
    condition     = !var.enable_psc || var.psc_subnet_cidr != null
    error_message = "When enable_psc is true, set psc_subnet_cidr (e.g. 10.0.64.0/29)."
  }
}

variable "ncc_spoke_site_to_site_data_transfer" {
  type        = bool
  default     = false
  description = "NCC router appliance spoke site_to_site_data_transfer flag (passed to controller via output)."
}
