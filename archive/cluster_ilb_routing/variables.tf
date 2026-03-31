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
  default     = "my-ilb-cluster"
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
  default     = 3
  description = "Number of worker nodes"
}

variable "availability_zone" {
  type        = string
  default     = "us-central1-a"
  description = "Single zone for the default worker pool. The machine type must exist in this zone."
}

variable "cudn_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "CUDN CIDR to route through the ILB to worker nodes"
}

variable "worker_subnet_to_cudn_firewall_mode" {
  type        = string
  default     = "e2etest"
  description = "Worker subnet → CUDN firewall: all | e2etest (default) | none. Passed to osd-ilb-routing."

  validation {
    condition     = contains(["all", "e2etest", "none"], var.worker_subnet_to_cudn_firewall_mode)
    error_message = "worker_subnet_to_cudn_firewall_mode must be all, e2etest, or none."
  }
}

variable "routing_worker_target_tags" {
  type        = list(string)
  default     = []
  description = "Optional network tags to scope worker→CUDN firewall to ILB backend workers. Empty = subnet-wide (lab default)."
}

variable "enable_ilb_routing" {
  type        = bool
  default     = false
  description = "Enable ILB routing to worker nodes. Set to true on the second apply after the cluster is fully provisioned and workers are running."
}

variable "enable_echo_client_vm" {
  type        = bool
  default     = false
  description = "Create an optional VM running icanhazip-clone for CUDN-to-VM direct IP verification. Requires enable_ilb_routing=true and outbound internet (Cloud NAT or public IP) for the initial podman image pull."
}

variable "echo_client_vm_zone" {
  type        = string
  default     = null
  description = "Zone for the echo VM. If null, uses the first worker zone."
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
