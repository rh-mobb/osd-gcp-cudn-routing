output "hub_vpc_id" {
  description = "Hub VPC network id (short form)"
  value       = google_compute_network.hub.id
}

output "hub_vpc_self_link" {
  description = "Hub VPC self link"
  value       = google_compute_network.hub.self_link
}

output "hub_vpc_name" {
  description = "Hub VPC name"
  value       = google_compute_network.hub.name
}

output "nat_ilb_forwarding_rule_self_link" {
  description = "Internal forwarding rule self link — use as next_hop_ilb from spoke routes"
  value       = google_compute_forwarding_rule.nat_gw_ilb.self_link
}

output "nat_ilb_ip" {
  description = "Reserved internal IPv4 of the NAT ILB"
  value       = google_compute_address.nat_ilb.address
}

output "egress_subnet_cidr" {
  description = "Primary CIDR of the hub egress subnet"
  value       = local.egress_cidr
}
