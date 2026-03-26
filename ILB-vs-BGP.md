# ILB vs BGP: Routing Approaches for OSD on GCP

This document compares two approaches for enabling direct, non-NATted
connectivity to pod and KubeVirt VM IPs on OpenShift Dedicated (OSD)
running on Google Cloud. Both solve the same problem -- making pod
network CIDRs routable from outside the cluster -- but differ
significantly in complexity, operational burden, and capability.

## The Problem

OVN-Kubernetes, the default CNI for OpenShift, creates an overlay
network (Geneve tunnels) for pod-to-pod communication. By default:

1. **Inbound**: The GCP VPC has no route to the pod overlay CIDR
   (e.g. `10.100.0.0/16`). External hosts cannot reach pods directly.
2. **Outbound**: OVN-Kubernetes SNATs all egress traffic through the
   node's IP. The pod's real IP is lost.

Both approaches solve these problems. Both require:

- **`canIpForward=true`** on worker GCE instances so GCP delivers
  packets whose destination IP doesn't match the instance's own IP.
- **RouteAdvertisements CR** to configure OVN's conditional SNAT so
  egress traffic from advertised networks preserves the pod source IP.
- **FRRConfiguration CR** (stub or real) to satisfy the
  RouteAdvertisements controller.
- **Bare metal instances** (or nested virtualization) for KubeVirt.

The difference is how inbound traffic reaches the correct worker node.

## Approach A: Internal Load Balancer (ILB) -- Implemented

### How It Works

```text
External Host
      │
      ▼
 VPC Route: 10.100.0.0/16 ──► ILB (next-hop)
      │
      ▼
 Internal Passthrough NLB
 (ECMP, 5-tuple hash)
      │
   ┌──┼──┐
   ▼  ▼  ▼
  W1  W2  W3   (canIpForward=true)
   │  │  │
   OVN Geneve Overlay
   │
   ▼
  Pod 10.100.0.5
```

A static VPC route sends all traffic for the CUDN CIDR to a GCP
Internal passthrough Network Load Balancer. The ILB distributes
traffic across healthy worker nodes. OVN-Kubernetes on the receiving
worker forwards the packet to the correct pod via the Geneve overlay.

### GCP Resources Required

The table below is the **core** set for Approach A. The reference implementation in this repository adds **additional** `google_compute_firewall` rules (for example **worker subnet → CUDN**, health checks, and optional **echo VM** SSH / CUDN→echo access). See [modules/osd-ilb-routing/README.md](modules/osd-ilb-routing/README.md) for the full resource list.

| Resource | Count | Purpose |
|----------|-------|---------|
| `google_compute_route` | 1 per CUDN CIDR | Static route: CIDR -> ILB |
| `google_compute_forwarding_rule` | 1 | ILB frontend |
| `google_compute_region_backend_service` | 1 | ILB backend (protocol UNSPECIFIED, passthrough) |
| `google_compute_instance_group` | 1 per zone | Groups worker instances as ILB backends |
| `google_compute_health_check` | 1 | TCP health check on workers |
| `google_compute_firewall` | 1+ | Health check probes to workers; **plus** reference-only rules (worker subnet → `cudn_cidr`, optional echo VM) |
| `google_compute_instance` (optional) | 0–1 | Echo VM for direct pod IP checks in the reference module |

### OpenShift Resources Required

| Resource | Purpose |
|----------|---------|
| `Network.operator.openshift.io` patch | Enable FRR + route advertisements |
| `ClusterUserDefinedNetwork` | Create the CUDN overlay (Layer2, Persistent IPAM) |
| `FRRConfiguration` (stub) | No BGP neighbors; declares routers for target VRFs |
| `RouteAdvertisements` | Configure conditional SNAT for the CUDN |

## Approach B: BGP via Cloud Router + NCC -- Implemented (reference module)

### How It Works

```text
External Host
      │
      ▼
 VPC Route Table
 (auto-populated by Cloud Router)
      │
      ▼
 Cloud Router (BGP, private ASN e.g. 64512)
      │
      │ BGP sessions via NCC Router Appliance
      │
   ┌──┼──┐
   ▼  ▼  ▼
  W1  W2  W3   (FRR + canIpForward=true)
   │  │  │     (frr-k8s peers with Cloud Router)
   OVN Geneve Overlay
   │
   ▼
  Pod 10.100.0.5
```

FRRouting (frr-k8s) on each worker node establishes BGP sessions with
a GCP Cloud Router. FRR advertises the CUDN prefixes to the Cloud
Router, which installs them as routes in the VPC routing table. Traffic
follows these dynamically learned routes to the correct worker.

### Critical Constraint: NCC Router Appliance

Google Cloud Router **cannot peer directly with Compute Engine VMs**.
An intermediary is required: Network Connectivity Center (NCC) with
Router Appliance spokes. This declares the worker VMs as "router
appliance" instances that Cloud Router is allowed to peer with.

### GCP Resources Required

| Resource | Count | Purpose |
|----------|-------|---------|
| `google_network_connectivity_hub` | 1 | Central NCC hub |
| `google_network_connectivity_spoke` | 1 | Router appliance spoke listing worker VMs |
| `google_compute_router` | 1 | Cloud Router with BGP ASN |
| `google_compute_router_peer` | 1 per worker | BGP session from Cloud Router to each worker |
| `google_compute_firewall` | 1-2 | Allow BGP (TCP 179) + health check probes |

No static `google_compute_route` is needed -- Cloud Router
auto-populates routes from learned BGP prefixes.

### OpenShift Resources Required

| Resource | Purpose |
|----------|---------|
| `Network.operator.openshift.io` patch | Enable FRR + route advertisements |
| `ClusterUserDefinedNetwork` | Create the CUDN overlay |
| `FRRConfiguration` (real) | **Per-node** configs: each worker peers only to **its** Cloud Router interface IP; `toReceive: all` on the neighbor; ASN must match Cloud Router (`cloud_router_asn` / `frr_asn` in Terraform). The reference script is [`cluster_bgp_routing/scripts/configure-routing.sh`](cluster_bgp_routing/scripts/configure-routing.sh). |
| `RouteAdvertisements` | Configure conditional SNAT + trigger FRR prefix advertisement |

### Additional IAM Requirements

The GCP service account needs roles not typically part of the standard
OSD WIF config:

- `roles/networkconnectivity.hubAdmin` -- create/manage NCC hubs
- `roles/networkconnectivity.spokeAdmin` -- create/manage NCC spokes
- `roles/compute.networkAdmin` -- manage Cloud Router and BGP peers

## Comparison

| Aspect | ILB (Approach A) | BGP (Approach B) |
|--------|-----------------|-----------------|
| **Complexity** | Low -- core GCP Compute resources only; the reference [ILB module](modules/osd-ilb-routing/README.md) adds optional echo VM and extra firewall rules | High -- NCC hub/spoke + Cloud Router + BGP peers |
| **Route management** | Static: one VPC route per CUDN CIDR, manually created | Dynamic: new CUDNs auto-advertised via BGP |
| **Adding a new CUDN** | New VPC route + ILB config required | Automatic -- FRR advertises the new prefix |
| **Failover mechanism** | ILB health check (TCP 10250, ~15s detection) | BGP keepalive timeout (~90s default, tunable) |
| **Failover granularity** | ILB removes unhealthy node from ECMP pool | Cloud Router withdraws route for failed node |
| **Load distribution** | ECMP across all healthy workers (5-tuple hash) | Cloud Router installs routes; single active path or ECMP depending on config |
| **Cross-network propagation** | Manual static routes in peered VPCs/VPNs | Cloud Router does NOT re-advertise learned routes across peering/VPN |
| **FRR configuration** | Stub (no neighbors, no active BGP sessions) | Real (Cloud Router IPs as neighbors, live BGP sessions) |
| **IAM requirements** | Standard OSD WIF permissions | Additional NCC + network admin roles |
| **GCP service dependencies** | Compute Engine only | Compute Engine + Network Connectivity Center |
| **Operational overhead** | Low -- static infrastructure, no protocol state | Higher -- BGP session monitoring, ASN management, NCC lifecycle |
| **Terraform provider maturity** | `google_compute_*` resources are stable and well-documented | `google_network_connectivity_*` + Router Appliance spokes are less common in examples; reference [**`modules/osd-bgp-routing`**](modules/osd-bgp-routing/README.md) |
| **Debugging** | `gcloud compute routes list`, ILB health status | `show bgp summary`, `show ip route`, NCC spoke status, Cloud Router logs |
| **Worker replacement** | Update instance group membership | Update NCC spoke VM list + Cloud Router peers |
| **Multi-CIDR support** | One VPC route per CIDR (linear scaling) | All CIDRs advertised via single BGP session (constant config) |
| **Standards alignment** | GCP-specific (ILB as next-hop is a GCP pattern) | Industry standard (BGP is universal routing protocol) |
| **Parity with ROSA-BGP** | Partial -- same OVN/SNAT behavior, different routing mechanism | Full -- same architecture as AWS VPC Route Server approach |
| **Overlap with everyday GCP networking** | High -- internal ILBs, VPC routes, regional backends, health checks, probe firewalls (same ingredients as many internal LB designs, including GKE `Service` internal load balancing) | Lower -- NCC hub/spoke, Router Appliance, Cloud Router BGP to workers; more common in hybrid / WAN-style engagements |

## ILB, GKE, and GCP support familiarity

This repository’s **ILB approach is not a claim that “GKE solves CUDN the same way.”** **Default GKE (VPC-native)** assigns pod addresses from **secondary IP ranges** on the VPC; those ranges participate in **VPC routing** directly. The **OVN CUDN** in this PoC is an **overlay** made reachable via **static route → ILB → workers** and **`canIpForward`**—a **different** problem shape than classic GKE pod CIDR integration.

The **useful parallel** is **operational and support familiarity**: the ILB path is built from **mainstream Compute + VPC + load balancing** primitives that GCP documents heavily and that practitioners encounter on **internal load balancing** workloads (including **GKE** when exposing **internal `Service` `LoadBalancers`**). The **BGP + NCC Router Appliance** path is **valid, first-party GCP**, but **narrower**: extra IAM, fewer copy-paste examples, and workflows more typical of **hybrid connectivity** specialists than of routine Kubernetes-on-GCP app networking.

**One-line summary:** **ILB aligns with common GCP internal-LB and static-route patterns; BGP+NCC aligns with advanced dynamic routing—often a smaller audience.**

For the OpenShift-focused AWS comparison (ROSA-BGP), see [cluster_ilb_routing/README.md](cluster_ilb_routing/README.md#comparison-with-rosa-bgp-on-aws-ilb-path).

## Why We Chose ILB for the PoC

1. **Simplest path to validate the data plane.** The core question
   was whether OVN-Kubernetes conditional SNAT works on a managed
   GCP platform. ILB lets us test this without introducing NCC, Cloud
   Router, or live BGP sessions. If the OVN behavior works with ILB
   routing, it will work identically with BGP routing -- the overlay
   doesn't care how the packet arrived at the worker.

2. **No dependency on NCC Router Appliance.** NCC is the most
   significant GCP-side complexity for the BGP approach. It requires
   additional IAM roles, less-documented Terraform resources, and
   introduces a new failure domain. For a PoC, this risk was
   unnecessary.

3. **Faster failover for testing.** ILB health checks detect node
   failure in ~15 seconds. BGP keepalive defaults are ~90 seconds.
   For a PoC where we're frequently cycling nodes and testing
   scenarios, faster failover is more practical.

4. **No ASN management.** BGP requires assigning and coordinating
   Autonomous System Numbers (ASNs) between the cluster (frr-k8s)
   and Cloud Router. For a PoC this is unnecessary overhead.

5. **Same OVN-K validation.** Both approaches use identical OpenShift
   resources (CUDN, RouteAdvertisements, FRRConfiguration). The only
   difference is whether the FRRConfiguration has real BGP neighbors
   or is a stub. The conditional SNAT behavior we need to validate
   is the same in both cases.

## When to Choose BGP

BGP becomes the better choice when:

- **Multiple CUDNs with different CIDRs** are created frequently.
  BGP advertises them automatically; ILB needs a new VPC route for
  each one.
- **Dynamic topology changes** are expected -- nodes added/removed
  frequently, CIDRs changing. BGP handles this without Terraform
  changes.
- **Cross-network propagation** is needed and can be solved with
  HA VPN + BGP (Cloud Router can advertise learned routes over VPN
  tunnels, unlike VPC peering).
- **Alignment with ROSA-BGP** is important for team knowledge
  sharing, documentation, and support patterns across AWS and GCP.
- **Production readiness** is the goal and the additional complexity
  is justified by the operational benefits.

## Migration Path: ILB to BGP

The ILB and BGP approaches share the same OpenShift-side **CUDN +
RouteAdvertisements + conditional SNAT** pattern. Migrating from ILB to BGP involves:

1. **Replace GCP infrastructure**: Swap the ILB module for [**`modules/osd-bgp-routing`**](modules/osd-bgp-routing/README.md) (NCC hub, spoke, Cloud Router, peers) or use the separate reference stack [**`cluster_bgp_routing/`**](cluster_bgp_routing/README.md).
2. **Update FRRConfiguration**: Replace the **stub** with **per-node** real BGP neighbors (Cloud Router interface IP **per worker**); remove **`stub-config`** and apply configs from the BGP **`configure-routing.sh`** (or equivalent GitOps).
3. **Remove static VPC route / ILB**: Cloud Router installs routes dynamically; tear down ILB resources to avoid duplicate paths.
4. **Align CUDN name / namespace** if you use different defaults (**`ilb-routing-cudn`** vs **`bgp-routing-cudn`** in the reference scripts).

The overlay and NAT behavior are the same once RouteAdvertisements and matching CUDN CIDRs are aligned; cutover still requires coordinated GCP and OpenShift changes.

**Reference:** one-shot deploy for BGP — **`make bgp-apply`** (see [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md) and root [README.md](README.md)).
