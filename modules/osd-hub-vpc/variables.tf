variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region (e.g. us-central1)"
}

variable "cluster_name" {
  type        = string
  description = "Prefix for resource names"
}

variable "hub_cidr" {
  type        = string
  description = "IPv4 CIDR for the hub VPC (e.g. 10.20.0.0/16). First /24 becomes the egress subnet."
}

variable "nat_vm_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Machine type for NAT gateway VMs"
}

variable "nat_vm_zones" {
  type        = list(string)
  description = "Zones for NAT VMs (one per zone in MIG target_size)"
}

variable "nat_ilb_host_offset" {
  type        = number
  default     = 5
  description = "Host index within the egress subnet CIDR reserved for the internal NLB VIP"
}

variable "health_check_port" {
  type        = number
  default     = 8080
  description = "TCP port for NLB health checks (nftables listens here after startup)"
}

variable "nat_gw_tag" {
  type        = string
  default     = "nat-gw"
  description = "Network tag applied to NAT VMs"
}

variable "ingress_source_ranges" {
  type        = list(string)
  description = "Source CIDRs allowed to forward traffic to NAT VMs (spoke subnets + CUDN + future)"
}

variable "healing_initial_delay_sec" {
  type        = number
  default     = 180
  description = "Auto-healing initial delay for NAT MIG"
}

variable "enable_iap_ssh" {
  type        = bool
  default     = true
  description = "Create a firewall rule allowing IAP TCP tunneling (35.235.240.0/20 → TCP/22) on NAT VMs so gcloud compute ssh --tunnel-through-iap works without a public-IP SSH rule."
}
