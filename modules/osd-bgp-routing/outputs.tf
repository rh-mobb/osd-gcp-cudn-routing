output "ncc_hub_id" {
  description = "NCC hub resource ID"
  value       = google_network_connectivity_hub.cudn.id
}

output "ncc_hub_name" {
  description = "NCC hub name (controller uses this to create the spoke)"
  value       = google_network_connectivity_hub.cudn.name
}

output "ncc_spoke_prefix" {
  description = "NCC spoke name prefix — controller creates spokes {prefix}-0, {prefix}-1, … (max 8 instances per spoke)"
  value       = "${var.cluster_name}-ra-spoke"
}

output "cloud_router_id" {
  description = "Cloud Router self-link"
  value       = google_compute_router.cudn.id
}

output "cloud_router_name" {
  description = "Cloud Router name"
  value       = google_compute_router.cudn.name
}

output "cloud_router_interface_ips" {
  description = "Cloud Router private IPs [primary, redundant] — every router node peers with both"
  value = [
    google_compute_router_interface.primary.private_ip_address,
    google_compute_router_interface.redundant.private_ip_address,
  ]
}

output "cloud_router_asn" {
  description = "Cloud Router BGP ASN"
  value       = var.cloud_router_asn
}

output "frr_asn" {
  description = "FRR / node BGP ASN (pass-through for the controller)"
  value       = var.frr_asn
}

output "ncc_spoke_site_to_site_data_transfer" {
  description = "site_to_site_data_transfer flag (pass-through for the controller)"
  value       = var.ncc_spoke_site_to_site_data_transfer
}

