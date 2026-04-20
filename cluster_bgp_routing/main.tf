# Phase 1: VPC + OSD cluster (default worker pool; see compute_machine_type)

data "google_compute_zones" "available" {
  region = var.gcp_region
}

locals {
  sorted_region_zones = sort(data.google_compute_zones.available.names)
  # Default multi-AZ: first three zones in the region (typical OSD / GCP layout).
  default_availability_zones = (
    length(local.sorted_region_zones) >= 3
    ? slice(local.sorted_region_zones, 0, 3)
    : local.sorted_region_zones
  )
  cluster_availability_zones = var.availability_zones != null ? var.availability_zones : local.default_availability_zones

  # Bare metal SKUs are not available in every zone; pin the optional BM pool to one AZ (default: same as first default worker zone).
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
}

module "osd_vpc" {
  source = "git::https://github.com/rh-mobb/terraform-provider-osd-google.git//modules/osd-vpc"

  project_id             = var.gcp_project_id
  region                 = var.gcp_region
  cluster_name           = var.cluster_name
  enable_psc             = var.enable_psc
  enable_private_cluster = var.enable_psc
}

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
    vpc_name             = module.osd_vpc.vpc_name
    control_plane_subnet = module.osd_vpc.control_plane_subnet
    compute_subnet       = module.osd_vpc.compute_subnet
  }

  private_service_connect = var.enable_psc ? {
    service_attachment_subnet = module.osd_vpc.psc_subnet
  } : null

  create_admin   = true
  admin_password = var.admin_password != "" ? var.admin_password : null

  machine_pools = var.create_baremetal_worker_pool ? [local.baremetal_machine_pool] : []
}

# Phase 2: BGP / NCC / Cloud Router (static infra only — controller manages spoke + peers)

module "bgp_routing" {
  source = "../modules/osd-bgp-routing"

  count = var.enable_bgp_routing ? 1 : 0

  # Subnet is created in module.osd_vpc; data.google_compute_subnetwork.worker reads GCP during
  # apply — without this, first plan/apply fails with "subnetwork not found".
  depends_on = [module.osd_vpc]

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  cluster_name = var.cluster_name
  vpc_id       = module.osd_vpc.vpc_id
  subnet_id    = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${module.osd_vpc.compute_subnet}"
  cudn_cidr    = var.cudn_cidr

  worker_subnet_to_cudn_firewall_mode = var.worker_subnet_to_cudn_firewall_mode
  routing_worker_target_tags          = var.routing_worker_target_tags

  cloud_router_asn                   = var.cloud_router_asn
  frr_asn                            = var.frr_asn
  bgp_interface_host_offset          = var.bgp_interface_host_offset
  router_interface_private_ips       = var.router_interface_private_ips
  reserve_cloud_router_interface_ips = var.reserve_cloud_router_interface_ips

  ncc_spoke_site_to_site_data_transfer = var.ncc_spoke_site_to_site_data_transfer

  enable_echo_client_vm       = var.enable_echo_client_vm
  echo_client_vm_zone         = var.echo_client_vm_zone != null ? var.echo_client_vm_zone : local.cluster_availability_zones[0]
  echo_client_vm_port         = var.echo_client_vm_port
  echo_client_vm_machine_type = var.echo_client_vm_machine_type
}
