# ILB-based routing for OSD pod networks (CUDN)
#
# Routes traffic for a CUDN CIDR through an Internal passthrough NLB
# to OSD worker nodes, enabling direct non-NATted connectivity to
# pod/VM IPs from the VPC and connected networks.

locals {
  zones = distinct([for inst in var.router_instances : inst.zone])

  instances_by_zone = {
    for z in local.zones : z => [
      for inst in var.router_instances : inst.self_link if inst.zone == z
    ]
  }
}

# One unmanaged instance group per zone containing the worker instances.
# ILB backend services require instance groups, not individual instances.
resource "google_compute_instance_group" "routers" {
  for_each = local.instances_by_zone

  project   = var.project_id
  name      = "${var.cluster_name}-ilb-routers-${each.key}"
  zone      = each.key
  network   = var.vpc_id
  instances = each.value
}

resource "google_compute_health_check" "kubelet" {
  project = var.project_id
  name    = "${var.cluster_name}-ilb-health"

  # TCP connect to kubelet (default port 10250). Healthz on 10248 is
  # localhost-only on OpenShift; 10250 is reachable on the node IP.
  # Prefer a routing-specific readiness check in production.
  tcp_health_check {
    port = var.health_check_port
  }

  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_region_backend_service" "ilb" {
  project               = var.project_id
  name                  = "${var.cluster_name}-ilb-routing"
  region                = var.region
  protocol              = "UNSPECIFIED"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_health_check.kubelet.id]

  dynamic "backend" {
    for_each = google_compute_instance_group.routers
    content {
      group = backend.value.id
      # INTERNAL regional backend services require CONNECTION balancing (not UTILIZATION).
      # Do not set max_connections_per_instance — not valid for this non-managed (passthrough) backend.
      balancing_mode = "CONNECTION"
    }
  }
}

resource "google_compute_forwarding_rule" "ilb" {
  project               = var.project_id
  name                  = "${var.cluster_name}-ilb-fwd"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.ilb.id
  all_ports             = true
  network               = var.vpc_id
  subnetwork            = var.subnet_id
}

resource "google_compute_route" "cudn" {
  project      = var.project_id
  name         = "${var.cluster_name}-cudn-route"
  dest_range   = var.cudn_cidr
  network      = var.vpc_id
  next_hop_ilb = google_compute_forwarding_rule.ilb.id
  priority     = 900
}
