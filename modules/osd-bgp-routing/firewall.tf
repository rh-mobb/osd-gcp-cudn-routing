# Uses data.google_compute_subnetwork.worker from main.tf for the worker subnet CIDR.

locals {
  routing_firewall_target_tags = length(var.routing_worker_target_tags) > 0 ? var.routing_worker_target_tags : null

  worker_subnet_to_cudn_desc = (
    var.worker_subnet_to_cudn_firewall_mode == "none" ? "disabled" :
    var.worker_subnet_to_cudn_firewall_mode == "all" ? "All protocols: worker subnet to CUDN (BGP-learned routes)" :
    "E2E-minimal: ICMP + TCP/80 from worker subnet to CUDN (use mode=all for production traffic)"
  )
}

# Allow traffic from the worker/compute subnet to addresses in the CUDN range.
resource "google_compute_firewall" "worker_subnet_to_cudn" {
  count = var.worker_subnet_to_cudn_firewall_mode == "none" ? 0 : 1

  project     = var.project_id
  name        = "${var.cluster_name}-worker-subnet-to-cudn"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 900
  description = local.worker_subnet_to_cudn_desc

  source_ranges      = [data.google_compute_subnetwork.worker.ip_cidr_range]
  destination_ranges = [var.cudn_cidr]
  target_tags        = local.routing_firewall_target_tags

  dynamic "allow" {
    for_each = var.worker_subnet_to_cudn_firewall_mode == "all" ? [1] : []
    content {
      protocol = "all"
    }
  }

  dynamic "allow" {
    for_each = var.worker_subnet_to_cudn_firewall_mode == "e2etest" ? [1] : []
    content {
      protocol = "icmp"
    }
  }

  dynamic "allow" {
    for_each = var.worker_subnet_to_cudn_firewall_mode == "e2etest" ? [1] : []
    content {
      protocol = "tcp"
      ports    = ["80"]
    }
  }
}

# BGP (TCP 179) between Cloud Router interface IPs and worker nodes in the same subnet.
resource "google_compute_firewall" "bgp_worker_subnet" {
  project     = var.project_id
  name        = "${var.cluster_name}-bgp-worker-subnet"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 900
  description = length(var.routing_worker_target_tags) > 0 ? "BGP tcp/179: scoped to routing_worker_target_tags" : "BGP tcp/179: worker subnet to worker subnet (lab default)"

  source_ranges = [data.google_compute_subnetwork.worker.ip_cidr_range]
  # With target tags, restrict to router-appliance instances; without tags, mirror legacy subnet-wide match.
  destination_ranges = local.routing_firewall_target_tags == null ? [data.google_compute_subnetwork.worker.ip_cidr_range] : null
  target_tags        = local.routing_firewall_target_tags

  allow {
    protocol = "tcp"
    ports    = ["179"]
  }
}
