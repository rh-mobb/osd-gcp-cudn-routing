# BGP-based CUDN routing: NCC Router Appliance + Cloud Router BGP to workers.
# Learned routes populate the VPC; no static google_compute_route to an ILB.
#
# GCP Router Appliance architecture (per official docs):
#   - Cloud Router gets exactly TWO interfaces (primary + redundant HA pair).
#   - Each router appliance instance peers with BOTH interfaces (2 BGP peers per worker).
#   - redundant_interface is one-directional: the second interface references the first.

locals {
  zones = distinct([for inst in var.router_instances : inst.zone])

  worker_subnet_path = replace(var.subnet_id, "https://www.googleapis.com/compute/v1/", "")
  worker_subnet      = regex("^projects/(?P<project>[^/]+)/regions/(?P<region>[^/]+)/subnetworks/(?P<name>[^/]+)$", local.worker_subnet_path)

  # Stable ordering: same index order as BGP peers (sort by GCE name).
  instance_names_sorted = sort([for i in var.router_instances : i.name])
  sorted_instances = [
    for n in local.instance_names_sorted :
    one([for i in var.router_instances : i if i.name == n])
  ]

  # Exactly 2 IPs — one per Cloud Router interface (primary + redundant).
  router_private_ips = var.router_interface_private_ips != null ? var.router_interface_private_ips : [
    cidrhost(data.google_compute_subnetwork.worker.ip_cidr_range, var.bgp_interface_host_offset),
    cidrhost(data.google_compute_subnetwork.worker.ip_cidr_range, var.bgp_interface_host_offset + 1),
  ]
}

data "google_compute_subnetwork" "worker" {
  name    = local.worker_subnet.name
  region  = local.worker_subnet.region
  project = local.worker_subnet.project
}

# IPv4-only containment without cidrcontains (Terraform 1.8+): uint32 range vs worker subnet primary CIDR.
locals {
  worker_subnet_v4 = regex("^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})/([0-9]{1,2})$", data.google_compute_subnetwork.worker.ip_cidr_range)

  worker_subnet_v4_prefix_len = parseint(local.worker_subnet_v4[4], 10)

  worker_subnet_v4_net_u32 = (
    parseint(local.worker_subnet_v4[0], 10) * 16777216
    + parseint(local.worker_subnet_v4[1], 10) * 65536
    + parseint(local.worker_subnet_v4[2], 10) * 256
    + parseint(local.worker_subnet_v4[3], 10)
  )

  worker_subnet_v4_size = pow(2, 32 - local.worker_subnet_v4_prefix_len)

  router_private_ip_v4_u32 = [
    for ip in local.router_private_ips : (
      parseint(regex("^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$", ip)[0], 10) * 16777216
      + parseint(regex("^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$", ip)[1], 10) * 65536
      + parseint(regex("^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$", ip)[2], 10) * 256
      + parseint(regex("^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$", ip)[3], 10)
    )
  ]
}

check "router_interface_ip_count" {
  assert {
    condition     = var.router_interface_private_ips == null || length(var.router_interface_private_ips) == 2
    error_message = "router_interface_private_ips must be null or have exactly 2 elements (one per Cloud Router interface)."
  }
}

check "router_interface_ips_in_worker_subnet" {
  assert {
    condition = alltrue([
      for u32 in local.router_private_ip_v4_u32 :
      u32 >= local.worker_subnet_v4_net_u32 && u32 < local.worker_subnet_v4_net_u32 + local.worker_subnet_v4_size
    ])
    error_message = "Each Cloud Router interface IP must fall within the worker subnetwork primary IPv4 CIDR (see subnet data source and bgp_interface_host_offset or router_interface_private_ips)."
  }
}

resource "google_network_connectivity_hub" "cudn" {
  name        = "${var.cluster_name}-ncc-hub"
  project     = var.project_id
  description = "NCC hub for CUDN router appliance (OSD BGP routing)"
}

resource "google_network_connectivity_spoke" "router_appliance" {
  name        = "${var.cluster_name}-ra-spoke"
  location    = var.region
  project     = var.project_id
  description = "Router appliance spoke for OSD workers (BGP to Cloud Router)"

  hub = google_network_connectivity_hub.cudn.id

  linked_router_appliance_instances {
    site_to_site_data_transfer = var.ncc_spoke_site_to_site_data_transfer
    dynamic "instances" {
      for_each = var.router_instances
      content {
        virtual_machine = instances.value.self_link
        ip_address      = instances.value.ip_address
      }
    }
  }
}

resource "google_compute_router" "cudn" {
  name    = "${var.cluster_name}-cudn-cr"
  project = var.project_id
  region  = var.region
  network = var.vpc_id

  bgp {
    asn = var.cloud_router_asn
  }

  depends_on = [google_network_connectivity_spoke.router_appliance]
}

# Two Cloud Router interfaces (HA pair). The primary is created first; the
# redundant interface references it via redundant_interface (one-directional).
resource "google_compute_router_interface" "primary" {
  project = var.project_id
  region  = var.region
  name    = "${var.cluster_name}-cr-if-0"
  router  = google_compute_router.cudn.name

  subnetwork         = var.subnet_id
  private_ip_address = local.cloud_router_interface_ip_primary
}

resource "google_compute_router_interface" "redundant" {
  project = var.project_id
  region  = var.region
  name    = "${var.cluster_name}-cr-if-1"
  router  = google_compute_router.cudn.name

  subnetwork          = var.subnet_id
  private_ip_address  = local.cloud_router_interface_ip_redundant
  redundant_interface = google_compute_router_interface.primary.name
}

# Each router appliance instance gets 2 BGP peers — one on each interface.
resource "google_compute_router_peer" "worker_primary" {
  count = length(local.sorted_instances)

  project = var.project_id
  region  = var.region
  name    = "${var.cluster_name}-bgp-peer-${count.index}-0"
  router  = google_compute_router.cudn.name

  interface                 = google_compute_router_interface.primary.name
  peer_asn                  = var.frr_asn
  peer_ip_address           = local.sorted_instances[count.index].ip_address
  ip_address                = google_compute_router_interface.primary.private_ip_address
  router_appliance_instance = local.sorted_instances[count.index].self_link
}

resource "google_compute_router_peer" "worker_redundant" {
  count = length(local.sorted_instances)

  project = var.project_id
  region  = var.region
  name    = "${var.cluster_name}-bgp-peer-${count.index}-1"
  router  = google_compute_router.cudn.name

  interface                 = google_compute_router_interface.redundant.name
  peer_asn                  = var.frr_asn
  peer_ip_address           = local.sorted_instances[count.index].ip_address
  ip_address                = google_compute_router_interface.redundant.private_ip_address
  router_appliance_instance = local.sorted_instances[count.index].self_link
}
