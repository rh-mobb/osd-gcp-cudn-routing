# OSD BGP Routing Module (NCC + Cloud Router)

Creates **Network Connectivity Center** (NCC) hub and **Router Appliance** spoke, a **Cloud Router** with **BGP peers** to OSD worker VMs, and supporting firewall rules so **CUDN prefixes** can be learned into the VPC route table (no static `google_compute_route` to an ILB).

Set **`ref`** in the module source to a **Git tag** or **commit SHA** for reproducible installs.

## Usage

```hcl
module "bgp_routing" {
  source = "git::https://github.com/rh-mobb/osd-gcp-cudn-routing.git//modules/osd-bgp-routing?ref=main"

  project_id   = "my-project"
  region       = "us-central1"
  cluster_name = "my-cluster"
  vpc_id       = module.osd_vpc.vpc_id
  subnet_id    = "projects/my-project/regions/us-central1/subnetworks/my-cluster-worker-subnet"
  cudn_cidr    = "10.100.0.0/16"

  cloud_router_asn = 64512
  frr_asn          = 65003

  router_instances = [
    {
      name       = "cluster-worker-a1b2"
      self_link  = "https://www.googleapis.com/compute/v1/projects/..."
      zone       = "us-central1-a"
      ip_address = "10.0.1.5"
    },
    {
      name       = "cluster-worker-c3d4"
      self_link  = "https://www.googleapis.com/compute/v1/projects/..."
      zone       = "us-central1-a"
      ip_address = "10.0.1.6"
    },
  ]
}
```

Replace **`?ref=main`** with a **tag** or **SHA** before relying on the module in long-lived environments.

## Requirements

- **IAM:** principals applying this module need NCC and network permissions (e.g. `roles/networkconnectivity.hubAdmin`, `roles/networkconnectivity.spokeAdmin`, `roles/compute.networkAdmin`) in addition to usual Compute permissions. See [ILB-vs-BGP.md](../../ILB-vs-BGP.md).
- **`canIpForward=true`** on worker VMs **before** **`google_network_connectivity_spoke`** (not managed here). Use [`cluster_bgp_routing/scripts/enable-worker-can-ip-forward.sh`](../../cluster_bgp_routing/scripts/enable-worker-can-ip-forward.sh); see [**cluster_bgp_routing/README.md**](../../cluster_bgp_routing/README.md). **`configure-routing.sh`** re-applies the flag for ongoing / replaced nodes.
- **Cloud Router ASN:** the Terraform provider requires an **RFC 6996 private ASN** for `google_compute_router.bgp.asn` (default **64512**). Use the same value in **FRRConfiguration** on the cluster (`configure-routing.sh` reads `terraform output cloud_router_asn`).

## Resources Created

- `google_network_connectivity_hub`
- `google_network_connectivity_spoke` (linked router appliance instances)
- `google_compute_router`
- `google_compute_router_interface` — exactly **2** (primary + redundant HA pair); the redundant interface references the primary via **`redundant_interface`**
- `google_compute_router_peer` — **2 per worker** (one on each interface); N workers = 2N peers
- `google_compute_firewall` — worker subnet → CUDN; BGP TCP **179** within worker subnet
- (Optional) Echo VM and firewalls (same pattern as the ILB module)

## Cloud Router interface IPs

The Cloud Router has exactly **2 interfaces** (primary + redundant). By default, addresses are **`cidrhost(worker_subnet_cidr, bgp_interface_host_offset)`** and **`bgp_interface_host_offset + 1`**. Override with **`router_interface_private_ips`** (exactly 2 elements) if those addresses conflict with other hosts.

Outputs **`bgp_peer_matrix`** and **`cloud_router_interface_ips`** are consumed by **`configure-routing.sh`** to build **per-node `FRRConfiguration`** objects (each worker peers with **both** Cloud Router IPs).

## Optional Echo Client VM

Same behavior as [`modules/osd-ilb-routing`](../osd-ilb-routing/README.md): `enable_echo_client_vm`, ports, zone, machine type, and PoC SSH rule.
