output "ncc_hub_id" {
  description = "NCC hub resource ID"
  value       = google_network_connectivity_hub.cudn.id
}

output "ncc_spoke_id" {
  description = "Router appliance spoke ID"
  value       = google_network_connectivity_spoke.router_appliance.id
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
  description = "Cloud Router private IPs [primary, redundant] — every worker peers with both"
  value = [
    google_compute_router_interface.primary.private_ip_address,
    google_compute_router_interface.redundant.private_ip_address,
  ]
}

output "bgp_peer_matrix" {
  description = "Per-worker pairing: GCE instance name, Cloud Router neighbor IPs (both interfaces), worker IP (sorted by instance name)"
  value = [
    for i, inst in local.sorted_instances : {
      instance_name = inst.name
      cloud_router_ips = [
        google_compute_router_interface.primary.private_ip_address,
        google_compute_router_interface.redundant.private_ip_address,
      ]
      worker_ip_address = inst.ip_address
    }
  ]
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
