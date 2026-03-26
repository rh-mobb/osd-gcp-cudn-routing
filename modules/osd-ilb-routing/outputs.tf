output "ilb_forwarding_rule_id" {
  description = "Self-link of the ILB forwarding rule"
  value       = google_compute_forwarding_rule.ilb.id
}

output "route_id" {
  description = "Self-link of the VPC route for the CUDN CIDR"
  value       = google_compute_route.cudn.id
}

output "health_check_id" {
  description = "Self-link of the ILB health check"
  value       = google_compute_health_check.kubelet.id
}

output "echo_client_vm_internal_ip" {
  description = "Primary internal IPv4 of the echo VM (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? google_compute_instance.echo_client[0].network_interface[0].network_ip : null
}

output "echo_client_vm_external_ip" {
  description = "Ephemeral external IPv4 of the echo VM (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? google_compute_instance.echo_client[0].network_interface[0].access_config[0].nat_ip : null
}

output "echo_client_vm_zone" {
  description = "Zone of the echo VM (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? local.echo_vm_zone : null
}

output "echo_client_http_url" {
  description = "HTTP URL for curl from CUDN pods: http://<ip>:<port>/ (null when enable_echo_client_vm is false)"
  value       = var.enable_echo_client_vm ? "http://${google_compute_instance.echo_client[0].network_interface[0].network_ip}:${var.echo_client_vm_port}/" : null
}
