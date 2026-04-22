output "vpc_id" {
  description = "Spoke VPC network id"
  value       = google_compute_network.spoke.id
}

output "vpc_self_link" {
  description = "Spoke VPC self link"
  value       = google_compute_network.spoke.self_link
}

output "vpc_name" {
  description = "Spoke VPC name — passed to osd-cluster as vpc_name"
  value       = google_compute_network.spoke.name
}

output "control_plane_subnet" {
  description = "Control plane subnetwork name"
  value       = google_compute_subnetwork.control_plane.name
}

output "compute_subnet" {
  description = "Compute subnetwork name"
  value       = google_compute_subnetwork.compute.name
}

output "psc_subnet" {
  description = "PSC subnetwork name (null when enable_psc is false)"
  value       = var.enable_psc ? google_compute_subnetwork.psc[0].name : null
}

output "control_plane_subnet_cidr" {
  value = var.control_plane_subnet_cidr
}

output "compute_subnet_cidr" {
  value = var.compute_subnet_cidr
}
