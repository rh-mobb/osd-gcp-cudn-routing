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

**Remote state:** use a **GCS** backend for shared or production environments; see [**docs/terraform-backend-gcs.md**](../../docs/terraform-backend-gcs.md) and [**cluster_bgp_routing/backend.tf.example**](../../cluster_bgp_routing/backend.tf.example).

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
- `google_compute_address` — **2×** INTERNAL **`GCE_ENDPOINT`** reservations for Cloud Router interface IPs when **`reserve_cloud_router_interface_ips`** is **true** (default)
- `google_compute_firewall` — worker subnet → CUDN (`worker_subnet_to_cudn_firewall_mode`: **`e2etest`** default = ICMP + TCP/80, **`all`**, or **`none`**); BGP TCP **179** (optional **`routing_worker_target_tags`** scoping)
- (Optional) Echo VM and firewalls (same pattern as the ILB module)

## Cloud Router interface IPs

The Cloud Router has exactly **2 interfaces** (primary + redundant). By default, addresses are **`cidrhost(worker_subnet_cidr, bgp_interface_host_offset)`** and **`bgp_interface_host_offset + 1`**. Override with **`router_interface_private_ips`** (exactly 2 elements) if those addresses conflict with other hosts. A **`check`** block requires every chosen IP to fall within the worker subnetwork’s **primary IPv4 CIDR**.

With **`reserve_cloud_router_interface_ips = true`** (default), Terraform creates **`google_compute_address`** (internal, **`GCE_ENDPOINT`**) for each IP so other workloads cannot steal them. Brownfield stacks that already have interfaces without reservations may need **`reserve_cloud_router_interface_ips = false`** on the first upgrade, then enable reservations during a window that allows recreating the router interfaces.

A **`check`** block validates interface IPs against the worker subnetwork **primary IPv4** CIDR (IPv4 **uint32** range math; works on Terraform **1.0+** without the **`cidrcontains`** function from **1.8+**).

Outputs **`bgp_peer_matrix`** and **`cloud_router_interface_ips`** are consumed by **`configure-routing.sh`** to build **per-node `FRRConfiguration`** objects (each worker peers with **both** Cloud Router IPs).

## Optional Echo Client VM

Same behavior as [`modules/osd-ilb-routing`](../osd-ilb-routing/README.md): `enable_echo_client_vm`, ports, zone, machine type. The VM is **internal-only**; SSH uses **IAP** (`gcloud compute ssh --tunnel-through-iap`) and a firewall rule for **`35.235.240.0/20`** to the echo VM’s network tags. Enable the **Identity-Aware Proxy API** and grant **`iap.tunnelInstances.accessViaIAP`** (or **IAP-secured Tunnel User**) to operators. **Lab / validation fixture only** — disable for production unless you accept the operational surface.
