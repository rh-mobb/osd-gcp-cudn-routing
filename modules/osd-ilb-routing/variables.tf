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
  description = "Worker subnet: full self_link URL or projects/PROJECT/regions/REGION/subnetworks/NAME (as used by cluster_ilb_routing)."
}

variable "cudn_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "CUDN prefix to route through the ILB to worker nodes"
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
    If non-empty, restrict the worker-subnet→CUDN firewall rule to instances with these network tags.
    Use for ILB backend / routing workers per GCP practice. Empty = all instances that match
    source/destination ranges (reference default).
  EOT
}

variable "router_instances" {
  type = list(object({
    self_link = string
    zone      = string
  }))
  description = "Worker instances to serve as ILB backends. Each entry needs self_link and zone."
}

variable "health_check_port" {
  type        = number
  default     = 10250
  description = <<-EOT
    TCP port for ILB health check. Default 10250 is kubelet's HTTPS API port, which listens on all interfaces on OpenShift/RHCOS.
    Kubelet healthz (10248) binds to 127.0.0.1 only, so GCP probes cannot reach it from the worker primary IP.
    A more precise routing readiness target (e.g. FRR) may be used in production.
  EOT
}

variable "enable_echo_client_vm" {
  type        = bool
  default     = false
  description = "Create an optional VM running icanhazip-clone for CUDN-to-VM direct IP verification. Requires outbound internet (Cloud NAT or public IP) for initial podman pull."
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
