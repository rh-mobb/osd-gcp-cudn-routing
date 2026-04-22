# Module: `osd-spoke-vpc`

Spoke VPC for **OpenShift Dedicated on GCP**: control-plane, worker, and optional PSC subnets.

Subnet **names** match **`rh-mobb/terraform-provider-osd-google`** **`modules/osd-vpc`** (`*-master-subnet`, `*-worker-subnet`, `*-psc-subnet`) so **`osd-cluster`** inputs stay compatible.

Peering and **`0.0.0.0/0`** default routes are applied in **`cluster_bgp_routing/`** after the hub exports the ILB.

## Outputs

Pass **`vpc_name`**, **`control_plane_subnet`**, **`compute_subnet`**, and optional **`psc_subnet`** to **`module "cluster"`**.

See [ARCHITECTURE.md](../../ARCHITECTURE.md).
