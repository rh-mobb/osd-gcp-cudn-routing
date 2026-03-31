output "gcp_project_id" {
  value       = var.gcp_project_id
  description = "GCP project ID"
}

output "gcp_region" {
  value       = var.gcp_region
  description = "GCP region"
}

output "availability_zone" {
  value       = var.availability_zone
  description = "Single zone used for workers and the echo VM (when echo_client_vm_zone is null)"
}

output "cluster_name" {
  value       = var.cluster_name
  description = "Cluster name"
}

output "cluster_id" {
  value       = module.cluster.cluster_id
  description = "OCM cluster ID"
}

output "api_url" {
  value       = module.cluster.api_url
  description = "Kubernetes API URL"
}

output "console_url" {
  value       = module.cluster.console_url
  description = "OpenShift web console URL"
}

output "admin_username" {
  value       = module.cluster.admin_username
  description = "Cluster admin username (when create_admin = true)"
}

output "admin_password" {
  value       = module.cluster.admin_password
  description = "Cluster admin password (sensitive; when create_admin = true)"
  sensitive   = true
}

output "worker_instances" {
  value       = [for inst in local.discovered_worker_instances : try(regex("[^/]+$", inst.selfLink), "unknown")]
  description = "Discovered machine-pool worker instance names (ILB backends)"
}

output "ilb_forwarding_rule_id" {
  value       = length(module.ilb_routing) > 0 ? module.ilb_routing[0].ilb_forwarding_rule_id : null
  description = "ILB forwarding rule self-link (null until workers are discovered)"
}

output "cudn_cidr" {
  value       = var.cudn_cidr
  description = "CUDN CIDR routed through the ILB"
}

output "echo_client_http_url" {
  value       = length(module.ilb_routing) > 0 ? module.ilb_routing[0].echo_client_http_url : null
  description = "HTTP URL for curl from CUDN pods (null when enable_echo_client_vm is false)"
}

output "echo_client_vm_internal_ip" {
  value       = length(module.ilb_routing) > 0 ? module.ilb_routing[0].echo_client_vm_internal_ip : null
  description = "Internal IPv4 of the echo VM (null when enable_echo_client_vm is false)"
}

output "echo_client_vm_zone" {
  value       = length(module.ilb_routing) > 0 ? module.ilb_routing[0].echo_client_vm_zone : null
  description = "Zone of the echo VM (null when enable_echo_client_vm is false)"
}

output "echo_client_vm_external_ip" {
  value       = length(module.ilb_routing) > 0 ? module.ilb_routing[0].echo_client_vm_external_ip : null
  description = "External IPv4 of the echo VM (null when enable_echo_client_vm is false)"
}
