# Phase 1: VPC + OSD cluster with bare metal workers

module "osd_vpc" {
  source = "git::https://github.com/rh-mobb/terraform-provider-osd-google.git//modules/osd-vpc"

  project_id             = var.gcp_project_id
  region                 = var.gcp_region
  cluster_name           = var.cluster_name
  enable_psc             = var.enable_psc
  enable_private_cluster = var.enable_psc
}

data "osdgoogle_machine_types" "baremetal" {
  region         = var.gcp_region
  gcp_project_id = var.gcp_project_id
}

locals {
  machine_type_ids = [for item in data.osdgoogle_machine_types.baremetal.items : item.id]
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

module "cluster" {
  source = "git::https://github.com/rh-mobb/terraform-provider-osd-google.git//modules/osd-cluster"

  name           = var.cluster_name
  cloud_region   = var.gcp_region
  gcp_project_id = var.gcp_project_id

  openshift_version    = var.openshift_version
  compute_nodes        = var.compute_nodes
  compute_machine_type = var.compute_machine_type
  availability_zones   = [var.availability_zone]
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
}

# Phase 2: Discover workers and create BGP / NCC / Cloud Router

data "external" "workers" {
  count = var.enable_bgp_routing ? 1 : 0

  program = ["bash", "${path.module}/scripts/discover-workers.sh"]

  query = {
    project      = var.gcp_project_id
    zone         = var.availability_zone
    cluster_name = var.cluster_name
  }
}

locals {
  # Avoid indexing data.external.workers[0] when count = 0 (enable_bgp_routing false).
  discovered_instances = length(data.external.workers) > 0 ? try(jsondecode(data.external.workers[0].result.instances), []) : []

  discovered_worker_instances = [
    for inst in local.discovered_instances : inst
    if can(regex(".*-worker-.*", try(inst.name, try(regex("[^/]+$", inst.selfLink), ""))))
  ]

  worker_instances = [
    for inst in local.discovered_worker_instances : {
      name       = inst.name
      self_link  = inst.selfLink
      zone       = regex("zones/([^/]+)$", inst.zone)[0]
      ip_address = inst.networkIP
    }
  ]
}

check "worker_network_ip" {
  assert {
    condition = !var.enable_bgp_routing || alltrue([
      for w in local.worker_instances : w.ip_address != null && w.ip_address != ""
    ])
    error_message = "Worker discovery returned an empty networkIP for at least one worker. Check gcloud / discover-workers.sh."
  }
}

module "bgp_routing" {
  source = "../modules/osd-bgp-routing"

  count = var.enable_bgp_routing ? 1 : 0

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  cluster_name = var.cluster_name
  vpc_id       = module.osd_vpc.vpc_id
  subnet_id    = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${module.osd_vpc.compute_subnet}"
  cudn_cidr    = var.cudn_cidr

  worker_subnet_to_cudn_firewall_mode = var.worker_subnet_to_cudn_firewall_mode
  routing_worker_target_tags          = var.routing_worker_target_tags

  router_instances = local.worker_instances

  cloud_router_asn                   = var.cloud_router_asn
  frr_asn                            = var.frr_asn
  bgp_interface_host_offset          = var.bgp_interface_host_offset
  router_interface_private_ips       = var.router_interface_private_ips
  reserve_cloud_router_interface_ips = var.reserve_cloud_router_interface_ips

  ncc_spoke_site_to_site_data_transfer = var.ncc_spoke_site_to_site_data_transfer

  enable_echo_client_vm       = var.enable_echo_client_vm
  echo_client_vm_zone         = var.echo_client_vm_zone
  echo_client_vm_port         = var.echo_client_vm_port
  echo_client_vm_machine_type = var.echo_client_vm_machine_type
}
