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

# Phase 2: Discover worker instances and create ILB routing
#
# Worker instances are created by OCM, not Terraform. Set
# enable_ilb_routing = true on the second apply after the cluster
# is fully provisioned and workers are running.

data "external" "workers" {
  count = var.enable_ilb_routing ? 1 : 0

  program = ["bash", "${path.module}/scripts/discover-workers.sh"]

  query = {
    project      = var.gcp_project_id
    zone         = var.availability_zone
    cluster_name = var.cluster_name
  }
}

locals {
  discovered_instances = var.enable_ilb_routing ? try(jsondecode(data.external.workers[0].result.instances), []) : []

  # Defensive filter: only machine-pool workers (compute subnet). Masters/infra
  # cannot be ILB backends for a worker-subnet forwarding rule.
  discovered_worker_instances = [
    for inst in local.discovered_instances : inst
    if can(regex(".*-worker-.*", try(regex("[^/]+$", inst.selfLink), "")))
  ]

  worker_instances = [
    for inst in local.discovered_worker_instances : {
      self_link = inst.selfLink
      zone      = regex("zones/([^/]+)$", inst.zone)[0]
    }
  ]
}

module "ilb_routing" {
  source = "../modules/osd-ilb-routing"

  count = var.enable_ilb_routing ? 1 : 0

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  cluster_name = var.cluster_name
  vpc_id       = module.osd_vpc.vpc_id
  subnet_id    = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${module.osd_vpc.compute_subnet}"
  cudn_cidr    = var.cudn_cidr

  router_instances = local.worker_instances

  enable_echo_client_vm       = var.enable_echo_client_vm
  echo_client_vm_zone         = var.echo_client_vm_zone
  echo_client_vm_port         = var.echo_client_vm_port
  echo_client_vm_machine_type = var.echo_client_vm_machine_type
}
