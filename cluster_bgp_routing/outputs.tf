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
  description = "Single zone used for the default worker pool and the echo VM (when echo_client_vm_zone is null)"
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

output "cloud_router_interface_ips" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].cloud_router_interface_ips : []
  description = "Cloud Router interface IPs [primary, redundant] — every router node peers with both"
}

output "cloud_router_name" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].cloud_router_name : null
  description = "Cloud Router name"
}

output "ncc_hub_id" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].ncc_hub_id : null
  description = "NCC hub ID (null until enable_bgp_routing)"
}

output "ncc_hub_name" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].ncc_hub_name : null
  description = "NCC hub name — controller uses this to create the spoke"
}

output "ncc_spoke_name" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].ncc_spoke_name : null
  description = "Expected NCC spoke name (created by the controller)"
}

output "cloud_router_id" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].cloud_router_id : null
  description = "Cloud Router ID (null until enable_bgp_routing)"
}

output "cudn_cidr" {
  value       = var.cudn_cidr
  description = "CUDN CIDR advertised via BGP"
}

output "cloud_router_asn" {
  value       = var.cloud_router_asn
  description = "Cloud Router BGP ASN"
}

output "frr_asn" {
  value       = var.frr_asn
  description = "FRR / node BGP ASN"
}

output "echo_client_http_url" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].echo_client_http_url : null
  description = "HTTP URL for curl from CUDN pods (null when enable_echo_client_vm is false)"
}

output "echo_client_vm_internal_ip" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].echo_client_vm_internal_ip : null
  description = "Internal IPv4 of the echo VM (null when enable_echo_client_vm is false)"
}

output "echo_client_vm_zone" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].echo_client_vm_zone : null
  description = "Zone of the echo VM (null when enable_echo_client_vm is false)"
}

output "echo_client_vm_external_ip" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].echo_client_vm_external_ip : null
  description = "External IPv4 of the echo VM (null when enable_echo_client_vm is false)"
}
