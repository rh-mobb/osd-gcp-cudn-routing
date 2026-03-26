# Uses data.google_compute_subnetwork.worker from main.tf for the worker subnet CIDR.

# Allow traffic from the worker/compute subnet to addresses in the CUDN range.
resource "google_compute_firewall" "worker_subnet_to_cudn" {
  project     = var.project_id
  name        = "${var.cluster_name}-worker-subnet-to-cudn"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 900
  description = "All protocols: worker subnet (e.g. echo VM) to CUDN via learned routes"

  source_ranges      = [data.google_compute_subnetwork.worker.ip_cidr_range]
  destination_ranges = [var.cudn_cidr]

  allow {
    protocol = "all"
  }
}

# BGP (TCP 179) between Cloud Router interface IPs and worker nodes in the same subnet.
resource "google_compute_firewall" "bgp_worker_subnet" {
  project     = var.project_id
  name        = "${var.cluster_name}-bgp-worker-subnet"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 900
  description = "BGP sessions: Cloud Router interfaces and router appliance workers"

  source_ranges      = [data.google_compute_subnetwork.worker.ip_cidr_range]
  destination_ranges = [data.google_compute_subnetwork.worker.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["179"]
  }
}
