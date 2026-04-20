output "gcp_project_id" {
  value       = var.gcp_project_id
  description = "GCP project ID"
}

output "gcp_region" {
  value       = var.gcp_region
  description = "GCP region"
}

output "availability_zone" {
  value       = local.cluster_availability_zones[0]
  description = "First zone in the default worker pool (backward compatibility; echo VM default when echo_client_vm_zone is null)"
}

output "availability_zones" {
  value       = local.cluster_availability_zones
  description = "GCP zones used for the default worker pool"
}

# Zonal Hyperdisk storage pools must live in the same zone as workers that attach volumes.
# Bare metal Virt is pinned to baremetal_availability_zones (single AZ); default workers may be multi-AZ.
output "virt_storage_zone" {
  value       = var.create_baremetal_worker_pool ? local.baremetal_availability_zones[0] : local.cluster_availability_zones[0]
  description = "GCP zone for Hyperdisk pool + sp-balanced-storage (deploy-openshift-virt.sh) — bare metal pool zone when create_baremetal_worker_pool is true, else first default worker zone"
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

output "ncc_spoke_prefix" {
  value       = length(module.bgp_routing) > 0 ? module.bgp_routing[0].ncc_spoke_prefix : null
  description = "NCC spoke name prefix — controller creates spokes {prefix}-0, {prefix}-1, …"
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

output "ncc_spoke_site_to_site_data_transfer" {
  value       = var.ncc_spoke_site_to_site_data_transfer
  description = "NCC spoke site_to_site_data_transfer (controller ConfigMap NCC_SPOKE_SITE_TO_SITE)"
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
