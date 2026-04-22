locals {
  # Align with rh-mobb/terraform-provider-osd-google modules/osd-vpc subnet naming.
  cp_name = coalesce(var.control_plane_subnet_name, "${var.cluster_name}-master-subnet")
  wl_name = coalesce(var.compute_subnet_name, "${var.cluster_name}-worker-subnet")
  psc_nm  = coalesce(var.psc_subnet_name, "${var.cluster_name}-psc-subnet")
}

resource "google_compute_network" "spoke" {
  project                 = var.project_id
  name                    = "${var.cluster_name}-spoke-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "control_plane" {
  project       = var.project_id
  name          = local.cp_name
  ip_cidr_range = var.control_plane_subnet_cidr
  region        = var.region
  network       = google_compute_network.spoke.id

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "compute" {
  project       = var.project_id
  name          = local.wl_name
  ip_cidr_range = var.compute_subnet_cidr
  region        = var.region
  network       = google_compute_network.spoke.id

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "psc" {
  count = var.enable_psc ? 1 : 0

  project       = var.project_id
  name          = local.psc_nm
  ip_cidr_range = var.psc_subnet_cidr
  region        = var.region
  network       = google_compute_network.spoke.id
  purpose       = "PRIVATE_SERVICE_CONNECT"
}

# Allow hub NAT VMs to route CUDN internet-egress return traffic back into the spoke.
# Without this, the spoke VPC firewall drops packets sourced from the hub egress subnet
# (10.20.0.x), causing asymmetric routing: outbound works, return is silently discarded.
resource "google_compute_firewall" "hub_to_spoke_return" {
  count = var.hub_egress_cidr != null ? 1 : 0

  project   = var.project_id
  name      = "${var.cluster_name}-hub-to-spoke-return"
  network   = google_compute_network.spoke.id
  direction = "INGRESS"
  priority  = 900

  source_ranges = [var.hub_egress_cidr]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  project   = var.project_id
  name      = "${var.cluster_name}-spoke-iap-ssh"
  network   = google_compute_network.spoke.id
  direction = "INGRESS"
  priority  = 900

  # IAP TCP proxy source range — https://cloud.google.com/iap/docs/using-tcp-forwarding
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
