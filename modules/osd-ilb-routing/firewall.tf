# Worker subnet CIDR (echo VM, test VMs, and worker primary IPs live here).
# Used so VPC ingress to CUDN-destined packets is allowed on ILB backends — see
# google_compute_firewall.worker_subnet_to_cudn below.
#
# cluster_ilb_routing passes subnet_id as
# projects/PROJECT/regions/REGION/subnetworks/NAME — not a full self_link URL,
# which data.google_compute_subnetwork.self_link rejects. Support both shapes.
locals {
  worker_subnet_path = replace(var.subnet_id, "https://www.googleapis.com/compute/v1/", "")
  worker_subnet      = regex("^projects/(?P<project>[^/]+)/regions/(?P<region>[^/]+)/subnetworks/(?P<name>[^/]+)$", local.worker_subnet_path)
}

data "google_compute_subnetwork" "worker" {
  name    = local.worker_subnet.name
  region  = local.worker_subnet.region
  project = local.worker_subnet.project
}

# Allow traffic from the worker/compute subnet to addresses in the CUDN range.
# Packets bound for 10.100.x.x are routed via the ILB and land on worker NICs
# with canIpForward; without this rule, osd-vpc's cluster_internal firewall
# (source + dest in master/worker CIDRs only) does not match dest = CUDN.
resource "google_compute_firewall" "worker_subnet_to_cudn" {
  project     = var.project_id
  name        = "${var.cluster_name}-worker-subnet-to-cudn"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 900
  description = "All protocols: worker subnet (e.g. echo VM) to CUDN via ILB path"

  source_ranges      = [data.google_compute_subnetwork.worker.ip_cidr_range]
  destination_ranges = [var.cudn_cidr]

  allow {
    protocol = "all"
  }
}

# Allow GCP health check probes to reach the kubelet healthz port
# on worker instances. GCP health checkers originate from these ranges:
# https://cloud.google.com/load-balancing/docs/health-check-concepts#ip-ranges
resource "google_compute_firewall" "health_check" {
  project = var.project_id
  name    = "${var.cluster_name}-ilb-health-check"
  network = var.vpc_id

  allow {
    protocol = "tcp"
    ports    = [tostring(var.health_check_port)]
  }

  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  direction = "INGRESS"
}
