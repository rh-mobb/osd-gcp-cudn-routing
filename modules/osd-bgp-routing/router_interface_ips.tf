# Internal static reservations for Cloud Router interface IPs (GCE_ENDPOINT in the worker subnetwork).
# Prevents other workloads from claiming the same addresses. Disable only if reservations
# are managed outside this module (see var.reserve_cloud_router_interface_ips).

resource "google_compute_address" "cloud_router_interface" {
  count = var.reserve_cloud_router_interface_ips ? 2 : 0

  name         = "${var.cluster_name}-cr-if-${count.index}-addr"
  project      = var.project_id
  region       = var.region
  subnetwork   = var.subnet_id
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
  address      = local.router_private_ips[count.index]
}

locals {
  cloud_router_interface_ip_primary   = var.reserve_cloud_router_interface_ips ? google_compute_address.cloud_router_interface[0].address : local.router_private_ips[0]
  cloud_router_interface_ip_redundant = var.reserve_cloud_router_interface_ips ? google_compute_address.cloud_router_interface[1].address : local.router_private_ips[1]
}
