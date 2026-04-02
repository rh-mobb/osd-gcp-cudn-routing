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

output "echo_client_vm_internal_ip" {
  description = "Primary internal IPv4 of the echo VM (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? google_compute_instance.echo_client[0].network_interface[0].network_ip : null
}

output "echo_client_vm_external_ip" {
  description = "Always null: echo VM has no external IP; use gcloud compute ssh --tunnel-through-iap (null when enable_echo_client_vm is false)"
  value       = null
}

output "echo_client_vm_zone" {
  description = "Zone of the echo VM (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? local.echo_vm_zone : null
}

output "echo_client_http_url" {
  description = "HTTP URL for curl from CUDN pods (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? "http://${google_compute_instance.echo_client[0].network_interface[0].network_ip}:${var.echo_client_vm_port}/" : null
}
