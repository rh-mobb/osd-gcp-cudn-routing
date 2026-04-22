# OSD cluster + hub/spoke GCP networking:
# - Hub VPC: egress NAT VMs + internal NLB + Cloud NAT for hub subnet only.
# - Spoke VPC: OpenShift subnets (same naming as osd-vpc); default route → hub ILB via peering.

data "google_compute_zones" "available" {
  region = var.gcp_region
}

locals {
  sorted_region_zones = sort(data.google_compute_zones.available.names)

  default_availability_zones = (
    length(local.sorted_region_zones) >= 3
    ? slice(local.sorted_region_zones, 0, 3)
    : local.sorted_region_zones
  )

  cluster_availability_zones = var.availability_zones != null ? var.availability_zones : local.default_availability_zones

  baremetal_availability_zones = var.baremetal_availability_zones != null ? var.baremetal_availability_zones : [local.cluster_availability_zones[0]]

  baremetal_machine_pool = {
    name                = var.baremetal_machine_pool_name
    instance_type       = var.baremetal_instance_type
    autoscaling_enabled = false
    replicas            = var.baremetal_worker_replicas
    min_replicas        = null
    max_replicas        = null
    availability_zones  = local.baremetal_availability_zones
    labels              = {}
    taints              = []
    root_volume_size    = null
    secure_boot         = false
  }

  nat_vm_zones = slice(
    local.cluster_availability_zones,
    0,
    min(var.nat_vm_zone_limit, length(local.cluster_availability_zones))
  )

  hub_nat_ingress_sources = distinct(compact([
    var.control_plane_subnet_cidr,
    var.compute_subnet_cidr,
    var.cudn_cidr,
  ]))
}

module "hub" {
  source = "../modules/osd-hub-vpc"

  project_id            = var.gcp_project_id
  region                = var.gcp_region
  cluster_name          = var.cluster_name
  hub_cidr              = var.hub_vpc_cidr
  nat_vm_machine_type   = var.nat_vm_machine_type
  nat_vm_zones          = local.nat_vm_zones
  ingress_source_ranges = local.hub_nat_ingress_sources

  healing_initial_delay_sec = var.nat_healing_initial_delay_sec
  nat_ilb_host_offset       = var.nat_ilb_host_offset
  health_check_port         = var.nat_health_check_port
  enable_iap_ssh            = var.nat_enable_iap_ssh

  depends_on = [data.google_compute_zones.available]
}

module "spoke" {
  source = "../modules/osd-spoke-vpc"

  project_id                = var.gcp_project_id
  region                    = var.gcp_region
  cluster_name              = var.cluster_name
  control_plane_subnet_cidr = var.control_plane_subnet_cidr
  compute_subnet_cidr       = var.compute_subnet_cidr
  enable_psc                = var.enable_psc
  psc_subnet_cidr           = var.psc_subnet_cidr
  enable_iap_ssh            = var.spoke_enable_iap_ssh
  hub_egress_cidr           = module.hub.egress_subnet_cidr

  depends_on = [data.google_compute_zones.available]
}

resource "google_compute_network_peering" "hub_to_spoke" {
  name         = "${var.cluster_name}-peer-hub-to-spoke"
  network      = module.hub.hub_vpc_self_link
  peer_network = module.spoke.vpc_self_link

  export_custom_routes = true
  import_custom_routes = true
}

resource "google_compute_network_peering" "spoke_to_hub" {
  name         = "${var.cluster_name}-peer-spoke-to-hub"
  network      = module.spoke.vpc_self_link
  peer_network = module.hub.hub_vpc_self_link

  export_custom_routes = true
  import_custom_routes = true
}

resource "google_compute_route" "spoke_default_via_hub_nat" {
  project      = var.gcp_project_id
  name         = "${var.cluster_name}-default-via-hub-nat"
  dest_range   = "0.0.0.0/0"
  network      = module.spoke.vpc_id
  priority     = var.spoke_default_route_priority
  next_hop_ilb = module.hub.nat_ilb_ip

  depends_on = [
    google_compute_network_peering.hub_to_spoke,
    google_compute_network_peering.spoke_to_hub,
  ]
}

# ---- Echo VM (icanhazip-clone) in spoke worker subnet ------------------
locals {
  echo_vm_zone = var.echo_client_vm_zone != null ? var.echo_client_vm_zone : local.cluster_availability_zones[0]
  echo_vm_tags = ["${var.cluster_name}-echo-client"]
}

resource "google_compute_instance" "echo_client" {
  count = var.enable_echo_vm ? 1 : 0

  project      = var.gcp_project_id
  name         = "${var.cluster_name}-echo-client"
  machine_type = var.echo_client_vm_machine_type
  zone         = local.echo_vm_zone
  tags         = local.echo_vm_tags

  boot_disk {
    initialize_params {
      image = "projects/centos-cloud/global/images/family/centos-stream-9"
    }
  }

  network_interface {
    subnetwork = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${module.spoke.compute_subnet}"
    # No external IP — SSH via IAP: gcloud compute ssh --tunnel-through-iap
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      set -euxo pipefail
      dnf install -y podman || yum install -y podman
      systemctl stop firewalld 2>/dev/null || true
      systemctl disable firewalld 2>/dev/null || true
      podman rm -f icanhazip 2>/dev/null || true
      podman run -d --name icanhazip --restart=always -p ${var.echo_client_vm_port}:80 docker.io/thejordanprice/icanhazip-clone:latest
    EOT
  }

  allow_stopping_for_update = true

  depends_on = [module.spoke]
}

resource "google_compute_firewall" "echo_client_from_cudn" {
  count = var.enable_echo_vm ? 1 : 0

  project   = var.gcp_project_id
  name      = "${var.cluster_name}-echo-client-from-cudn"
  network   = module.spoke.vpc_id
  direction = "INGRESS"
  priority  = 900

  source_ranges = [var.cudn_cidr]
  target_tags   = local.echo_vm_tags

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "echo_client_ssh_iap" {
  count = var.enable_echo_vm && !var.spoke_enable_iap_ssh ? 1 : 0

  project     = var.gcp_project_id
  name        = "${var.cluster_name}-echo-client-ssh"
  network     = module.spoke.vpc_id
  direction   = "INGRESS"
  priority    = 900
  description = "IAP SSH for echo VM (gcloud compute ssh --tunnel-through-iap). Created only when spoke_enable_iap_ssh=false."

  source_ranges = ["35.235.240.0/20"]
  target_tags   = local.echo_vm_tags

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
# -------------------------------------------------------------------------

data "osdgoogle_machine_types" "osd_catalog" {
  region         = var.gcp_region
  gcp_project_id = var.gcp_project_id
}

locals {
  machine_type_ids = [for item in data.osdgoogle_machine_types.osd_catalog.items : item.id]
}

check "machine_type_available" {
  assert {
    condition     = contains(local.machine_type_ids, var.compute_machine_type)
    error_message = <<-EOT
      Instance type '${var.compute_machine_type}' is not available in region '${var.gcp_region}'.
      Available types: ${join(", ", local.machine_type_ids)}
    EOT
  }
}

check "baremetal_machine_type_available" {
  assert {
    condition     = !var.create_baremetal_worker_pool || contains(local.machine_type_ids, var.baremetal_instance_type)
    error_message = <<-EOT
      Bare metal instance type '${var.baremetal_instance_type}' is not listed in the OCM GCP catalog for '${var.gcp_region}'.
      Set baremetal_instance_type to a catalog id, set create_baremetal_worker_pool=false to skip the pool, or fix baremetal_availability_zones if the type is zone-specific.
      Catalog sample: ${join(", ", slice(local.machine_type_ids, 0, min(20, length(local.machine_type_ids))))}${length(local.machine_type_ids) > 20 ? ", ..." : ""}
    EOT
  }
}

module "cluster" {
  source = "git::https://github.com/rh-mobb/terraform-provider-osd-google.git//modules/osd-cluster"

  # No depends_on here: osd-cluster contains data.osdgoogle_wif_config which Terraform
  # defers to apply-time when the enclosing module has depends_on, making service_accounts
  # / support unknown and breaking for_each in osd-wif-gcp. Ordering is instead driven by
  # passing module.spoke outputs directly — .name attributes are user-set (known at plan)
  # and create an implicit dependency so the spoke VPC exists before OCM validates it.

  name           = var.cluster_name
  cloud_region   = var.gcp_region
  gcp_project_id = var.gcp_project_id

  openshift_version    = var.openshift_version
  compute_nodes        = var.compute_nodes
  compute_machine_type = var.compute_machine_type
  multi_az             = length(local.cluster_availability_zones) > 1
  availability_zones   = local.cluster_availability_zones
  ccs_enabled          = true

  gcp_network = {
    vpc_name             = module.spoke.vpc_name
    control_plane_subnet = module.spoke.control_plane_subnet
    compute_subnet       = module.spoke.compute_subnet
  }

  private_service_connect = var.enable_psc ? {
    service_attachment_subnet = module.spoke.psc_subnet
  } : null

  create_admin   = true
  admin_password = var.admin_password != "" ? var.admin_password : null

  machine_pools = var.create_baremetal_worker_pool ? [local.baremetal_machine_pool] : []
}

module "bgp_routing" {
  source = "../modules/osd-bgp-routing"

  count = var.enable_bgp_routing ? 1 : 0

  depends_on = [
    module.spoke,
    google_compute_route.spoke_default_via_hub_nat,
  ]

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  cluster_name = var.cluster_name
  vpc_id       = module.spoke.vpc_id
  subnet_id    = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${module.spoke.compute_subnet}"
  cudn_cidr    = var.cudn_cidr

  worker_subnet_to_cudn_firewall_mode = var.worker_subnet_to_cudn_firewall_mode
  routing_worker_target_tags          = var.routing_worker_target_tags

  cloud_router_asn                   = var.cloud_router_asn
  frr_asn                            = var.frr_asn
  bgp_interface_host_offset          = var.bgp_interface_host_offset
  router_interface_private_ips       = var.router_interface_private_ips
  reserve_cloud_router_interface_ips = var.reserve_cloud_router_interface_ips

  ncc_spoke_site_to_site_data_transfer = var.ncc_spoke_site_to_site_data_transfer
}
