# Architecture: CUDN BGP Routing on OSD-GCP

Definitive architecture for routing Cluster User-Defined Network (CUDN) traffic between OpenShift pods/VMs and the GCP VPC using BGP, NCC Router Appliance, and Cloud Router.

See [KNOWLEDGE.md](KNOWLEDGE.md) for the evidence base behind these decisions.

---

## Network topology (hub + spoke)

[GCP VPC](https://cloud.google.com/vpc/docs/vpc) networking is structured as:

- **Spoke VPC** ([`modules/osd-spoke-vpc`](modules/osd-spoke-vpc/)): OpenShift control-plane, worker, and optional PSC subnets (`*-master-subnet`, `*-worker-subnet`, `*-psc-subnet`). Same subnet **names** as upstream `osd-vpc` so `osd-cluster` plumbing is unchanged.
- **Hub VPC** ([`modules/osd-hub-vpc`](modules/osd-hub-vpc/)): egress-only tier — regional MIG of NAT VMs (**nftables MASQUERADE**), **internal passthrough NLB**, hub-only **Cloud NAT** for hub VM management traffic only.
- **VPC peering** (`google_compute_network_peering`): bidirectional **`export_custom_routes`** / **`import_custom_routes`** so BGP-learned CUDN prefixes can propagate to the hub where needed.
- **Default route** (spoke): **`0.0.0.0/0`** → **`next_hop_ilb`** (hub NLB forwarding rule). More-specific BGP and subnet routes retain priority over this default (`priority` configurable).
- **`cluster_bgp_routing/`**: wires hub → spoke → peering → default route → `osd-cluster` → optional `osd-bgp-routing`.

This avoids **Cloud NAT source registration** failures for CUDN-overlay sources and avoids **route tag** scoping on workers because NAT VMs are **not** in the spoke VPC.

---

## Problem

KubeVirt and migration workloads on OpenShift Dedicated need:

1. **Preserved pod/VM IPs** routable from the VPC and peered networks (no NAT on ingress).
2. **Egress without SNAT** so traffic leaving the cluster keeps the pod's CUDN IP as source.
3. **Uninterrupted connectivity during VM live migration** — the default pod network (masquerade) interrupts traffic during migration.

OVN's default behavior SNATs pod traffic through the node IP.
CUDNs give pods IPs from a dedicated subnet (`10.100.0.0/16`), but those IPs are invisible to the VPC unless routes are injected.

### Why CUDN + Layer2 for VMs

The default pod network uses masquerade (NAT) to connect VMs, and traffic is **interrupted during live migration** (OCP 4.21 Virtualization guide).
A **primary Layer2 UDN** with **`ipam.lifecycle: Persistent`** provides:

- **Persistent IPs** preserved across reboots and live migration.
- **NAT-free** connectivity — VMs are directly reachable by their CUDN IP.
- **Seamless live migration** without traffic interruption on the CUDN interface.

This is the [recommended topology for VMs on public clouds](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/) including GCP.

### Platform Support Note

BGP routing and route advertisements are officially documented as supported on **bare-metal infrastructure** only (OCP 4.21 Advanced Networking guide).
This deployment uses BGP on cloud VM workers (OSD-GCP), which is outside the **officially supported** matrix but works in practice and is the only viable option for managed cloud deployments.
The "bare metal only" language refers to Red Hat's support boundary — not a technical limitation.
The AWS reference uses `c5.metal` instances (bare-metal on AWS), which happens to be within the documented scope.

---

## Solution Overview

BGP advertises the CUDN prefix from worker nodes into the **spoke VPC** via NCC Router Appliance and Cloud Router (same logical model as before).

**Internet egress** leaves the spoke via **`0.0.0.0/0` → hub internal NLB → NAT VMs** — kernel **MASQUERADE** before packets reach the public Internet, independent of CUDN NIC registration semantics.

Every worker in the **candidate pool** (see `spec.nodeSelector` in `BGPRoutingConfig`, excluding infra) participates in BGP so it can:

- **Receive** inbound traffic directly (VPC route points to it as a valid next-hop).
- **Send** outbound traffic from CUDN pods using learned routes to VPC destinations.

```text
                         ┌──────────────────────────────────────┐
 Hub VPC                  │ NAT MIG ─ ILB ─ Cloud NAT (hub mgr) │
 (egress tier)            │ VPC peering ◄─────────────────────┼──┐
                         └──────────────────────────────────────┘  │
                                      ▲                               │
                                      │ default route (spoke)         │
                         ┌────────────┴──────────────────────────────┴─┐
 Spoke VPC               │ Echo VM │ Cloud Router │ NCC Hub              │
                         │          │ BGP          │ RA spokes ─ workers │
                         │          └──────────────┘                      │
                         │ VPC routes 10.100/16 → worker(s) ECMP       │
                         ├────────────────────────────────────────────┤
                         │ OpenShift │ Workers + FRR + CUDN overlay   │
                         └──────────────────────────────────────────────┘
```

---

## Why All Workers Must Be BGP Peers

The earlier design selected a small subset of "router nodes" and assumed OVN overlay would forward traffic from a router node to pods on other nodes.
Testing and cross-team collaboration revealed this does not work:

- **Outbound**: FRR runs on **all** nodes (the FRR-K8s daemon is deployed cluster-wide when enabled), and OVN-K generates FRRConfiguration CRs on every node to advertise the CUDN prefix.
However, workers **without** an operator-managed Cloud Router neighbor have **no learned VPC routes** — the FRRConfiguration CRs (which add Cloud Router as a BGP peer with `toReceive.allowed.mode: all`) must exist on every node that hosts CUDN workloads.
Without an external BGP neighbor, that node cannot learn VPC routes, and CUDN egress traffic has no path out.
- **Inbound**: with ECMP (confirmed), inbound traffic from the VPC is distributed across all peered workers.
A packet may arrive at a worker that does not host the target pod, requiring OVN overlay forwarding to the correct node.
Whether this overlay forwarding works reliably for CUDN traffic has not been conclusively tested.

The fix is straightforward: **every worker node that can host CUDN pods gets an operator-managed FRRConfiguration CR** that adds Cloud Router as a BGP neighbor.
Each node then advertises the CUDN prefix to Cloud Router and learns VPC routes, enabling both inbound and outbound traffic.
This matches the approach validated on AWS (all dedicated router nodes are peers) and eliminates the scheduling dependency.

---

## Components

### GCP Infrastructure (Terraform — static)

Created once by `terraform apply` in `cluster_bgp_routing/`.

| Resource | Purpose |
|----------|---------|
| **Hub VPC** (`modules/osd-hub-vpc`) | Egress subnet, NAT VM MIG, internal NLB VIP, hub Cloud Router NAT (hub subnet only) |
| **Spoke VPC** (`modules/osd-spoke-vpc`) | Master / worker / optional PSC subnets (OSD-aligned names) |
| **VPC peerings** (hub ↔ spoke) | Bidirectional custom routes for default route + CUDN propagation |
| **Static route** (spoke) | `0.0.0.0/0` → hub NLB (`next_hop_ilb`) |
| **NCC Hub** | Network Connectivity Center hub anchoring the router appliance topology |
| **Cloud Router** (ASN `64512`) | Learns CUDN routes from workers via BGP; injects into **spoke** VPC route table |
| **Cloud Router Interfaces** (x2) | HA pair (primary + redundant); each worker peers with both |
| **Interface IP Reservations** (x2) | `google_compute_address` (INTERNAL) preventing IP collisions |
| **Firewall: worker-subnet-to-cudn** | Allows traffic from VPC subnet to CUDN CIDR |
| **Firewall: bgp-worker-subnet** | Allows TCP/179 between Cloud Router IPs and workers |
| **Echo VM** (optional) | Test VM on the worker subnet for e2e validation |

### GCP Infrastructure (Operator — dynamic)

Managed by the BGP routing operator on every reconciliation cycle.

| Resource | Purpose |
|----------|---------|
| **NCC Spokes** | One or more spokes named `{NCC_SPOKE_PREFIX}-0`, `{NCC_SPOKE_PREFIX}-1`, … — each links up to **8** worker GCE instances (GCP limit) to the NCC hub |
| **Cloud Router BGP Peers** | 2 peers per worker (one per Cloud Router interface); eBGP to FRR |
| **`canIpForward`** | Enabled on each worker GCE instance so it can forward CUDN traffic |

### OpenShift / Kubernetes (one-time setup)

Applied by `configure-routing.sh` after cluster creation.

| Resource | Purpose |
|----------|---------|
| **Network operator patch** | Enables `additionalRoutingCapabilities.providers: [FRR]` and `routeAdvertisements: Enabled` |
| **Namespace** (`cudn1`) | Labeled `k8s.ovn.org/primary-user-defined-network` and `cluster-udn: prod` |
| **ClusterUserDefinedNetwork** | Layer2 topology, `10.100.0.0/16`, `ipam.lifecycle: Persistent`, label `advertise: "true"` |
| **RouteAdvertisements** | `nodeSelector: {}` (required with `PodNetwork`), `frrConfigurationSelector: {}`, selects CUDNs labeled `advertise: "true"` |

### OpenShift / Kubernetes (operator-managed)

| Resource | Purpose |
|----------|---------|
| **`BGPRoutingConfig` CR** | Singleton (`cluster`); declarative spec for all routing config; `.status` reports aggregated reconciliation state |
| **`BGPRouter` CRs** | One per elected router node; operator-managed status objects showing per-node GCP/FRR health |
| **`FRRConfiguration` CRs** | One per worker node; targets single node via `kubernetes.io/hostname`; 2 Cloud Router neighbors with `disable-connected-check` in `spec.raw` |
| **Node label** `routing.osd.redhat.com/bgp-router` | Applied to all candidate workers for **`oc get -l`** / affinity if you add it elsewhere |
| **Node annotations** `routing.osd.redhat.com/gcp-can-ip-forward`, `routing.osd.redhat.com/gcp-nested-virtualization` | Set after successful GCE **`canIpForward`** / nested virt reconcile; removed with the router label on cleanup or when nested virt is disabled |

### OVN-K Generated (automatic)

| Resource | Purpose |
|----------|---------|
| **`ovnk-generated-*` FRRConfiguration CRs** | Created by OVN-K on every node because `RouteAdvertisements` uses `nodeSelector: {}`; merged with operator CRs by MetalLB admission |
| **Conditional SNAT** | OVN applies SNAT only for cluster-internal destinations; CUDN egress preserves pod IP |

---

## Data Plane

### Ingress: VPC Host → CUDN Pod

```text
Spoke VPC host (10.0.x.x)
  │
  │  dst: 10.100.x.x (CUDN pod IP)
  ▼
Spoke VPC route table
  │  10.100.0.0/16 → Worker N (learned via BGP from Cloud Router)
  ▼
Worker N (GCE instance, canIpForward=true)
  │
  │  If pod is on this node: deliver locally via OVN
  │  If pod is on another node: forward via OVN overlay (Layer2)
  ▼
CUDN Pod (10.100.x.x)
```

Cloud Router uses **ECMP** when multiple router appliances advertise the same prefix with the same MED ([Router Appliance overview](https://cloud.google.com/network-connectivity/docs/network-connectivity-center/concepts/ra-overview)).
With all workers advertising the same `/16` and the same MED, GCP distributes inbound traffic across all workers based on a 5-tuple hash (src/dst IP, ports, protocol).
For a given flow the hash is deterministic — it always selects the **same** worker.
With N workers, there is a `1/N` chance the selected worker is the one hosting the target pod; for other flows the receiving worker must forward via the OVN overlay to the correct node.

### Egress: CUDN Pod → VPC Host

```text
CUDN Pod (10.100.x.x)
  │
  │  dst: 10.0.x.x (VPC host) — source IP preserved (no SNAT)
  ▼
OVN Layer2 network
  │  Pod is on a Layer2 CUDN; OVN-K uses the Layer2TransitRouter
  │  to discover the gateway and forward non-local traffic to the
  │  host network stack.
  ▼
Worker node host routing table
  │  FRR installs learned BGP routes here.
  │  Learned route: 10.0.0.0/x via Cloud Router interface IP
  ▼
Cloud Router
  │
  ▼
Spoke VPC host (10.0.x.x)
```

The transition from the OVN Layer2 network to the host routing table is the critical step.
Without a Cloud Router BGP neighbor, FRR on the node has no routes to install — the host routing table has no path for CUDN egress traffic, and the packet is dropped.
This is the primary reason every CUDN-capable worker must have an operator-managed FRRConfiguration CR adding Cloud Router as a neighbor.

> **Open question**: whether the exact forwarding mechanism uses `routingViaHost` or VRF-lite is not yet confirmed for our non-VRF Layer2 topology.
> See [KNOWLEDGE.md § Open Questions](KNOWLEDGE.md#open-questions--updated).

### Intra-CUDN: Pod → Pod

```text
Pod A (10.100.0.10, Worker 2)
  │
  │  OVN Layer2 overlay — same broadcast domain
  ▼
Pod B (10.100.0.11, Worker 5)
```

OVN handles L2 forwarding for pods on the same CUDN across nodes.
No BGP involvement; works regardless of BGP peering.

### Isolation: Cross-CUDN

Pods on different CUDNs cannot communicate (strict isolation by default).
Worker host processes (`oc debug node`) also cannot reach CUDN pod IPs.

### Egress: CUDN / host → public Internet (hub NAT)

For **default route** internet traffic, the **spoke** route table sends **`0.0.0.0/0`** to the **hub internal passthrough NLB** (peered). Packets land on a **NAT VM**; **nftables** **MASQUERADE** rewrites the source to the instance’s **ephemeral public** path. This is independent of **Cloud NAT** policies in the spoke and of **CUDN** address registration on the worker NIC.

```text
CUDN pod (10.100.x) or node
  → OVN / host
  → default route 0.0.0.0/0
  → peered path
  → hub ILB
  → NAT VM
  → MASQUERADE
  → Internet
```

### Egress: Spoke → Google APIs (Private Google Access)

**Private Google Access** is enabled on **spoke** master and worker subnets. **Control plane and node** access to `*.googleapis.com` and management paths should use **PGA** and do not need the default-internet path. (If you enable `enable_psc = true`, the **PSC subnet** is created; a full private cluster may require **additional** PSC global resources as in upstream `osd-vpc` — validate for your OCP version.)

---

## Control Plane

### Reconciliation Loop

The BGP routing operator runs as a Deployment in the `bgp-routing-system` namespace.
It watches `BGPRoutingConfig` and Node events and runs periodic drift correction (default 60s).

```text
┌──────────────────────────────────────────────────────────┐
│                    Reconciliation                        │
│                                                          │
│  1. Discover candidates                                  │
│     - List nodes matching node_label_selector            │
│     - Exclude infra nodes (node-role.kubernetes.io/infra)│
│     - Require GCE providerID + InternalIP                │
│                                                          │
│  2. Use all candidates as router nodes                   │
│     - Sorted by GCE instance name (deterministic)        │
│                                                          │
│  3. Sync labels                                          │
│     - Apply routing.osd.redhat.com/bgp-router            │
│     - Remove from nodes no longer in the candidate pool  │
│                                                          │
│  4. Enable canIpForward                                  │
│     - GCE API: set canIpForward=true on each instance    │
│     - Annotate node: routing.osd.redhat.com/gcp-can-ip-forward │
│                                                          │
│  5. Reconcile NCC spokes                                 │
│     - Shard workers into chunks of ≤8 per spoke (GCP)    │
│     - Spoke IDs: {prefix}-0, {prefix}-1, …               │
│     - Delete stale numbered spokes no longer needed      │
│                                                          │
│  6. Reconcile Cloud Router BGP peers                     │
│     - 2 peers per worker (primary + redundant interface) │
│     - Desired state = exact set; drift is corrected      │
│                                                          │
│  7. Reconcile FRRConfiguration CRs                       │
│     - One CR per worker, namespace openshift-frr-k8s     │
│     - nodeSelector: kubernetes.io/hostname               │
│     - 2 neighbors (Cloud Router interface IPs)           │
│     - spec.raw: disable-connected-check per neighbor     │
│     - Delete stale CRs for removed nodes                 │
│                                                          │
│  8. Update BGPRouter status objects                      │
│     - One BGPRouter CR per elected router node           │
│     - Per-node conditions: CanIPForwardReady, etc.       │
└──────────────────────────────────────────────────────────┘
```

### Cleanup

The operator uses a **finalizer** on the `BGPRoutingConfig` CR. Deleting the CR triggers cleanup in reverse order:

1. Remove router labels (**`routing.osd.redhat.com/bgp-router`**) and operator GCP annotations from all nodes that had the label.
2. Delete all operator-managed `FRRConfiguration` CRs.
3. Clear Cloud Router BGP peers (full resource PUT, not patch).
4. Delete all NCC spokes matching `{NCC_SPOKE_PREFIX}-<number>`.
5. Delete `BGPRouter` status objects.
6. Remove finalizer, allowing the CR to be garbage collected.

**`spec.suspended: true`** provides temporary disable-with-cleanup (preserves config for re-enablement).

### Event-Driven + Periodic

- **Node watch**: triggers reconciliation when nodes are added, removed, or relabeled (debounced, default 5s).
- **Periodic**: drift correction every `reconcile_interval_seconds` (default 60s) catches out-of-band changes to GCP resources.

---

## GCP Architecture Details

### NCC + Router Appliance Model

GCP's Network Connectivity Center (NCC) provides the framework for advertising routes from non-GCP routers (or GCE instances acting as routers) into the VPC.
The components:

- **Hub**: a global NCC resource; one per CUDN routing setup.
- **Spoke**: a regional resource linking up to **8** GCE instances as "router appliance instances" to the hub.
Larger clusters use multiple spokes (`{prefix}-0`, `{prefix}-1`, …).
Each instance must have `canIpForward=true`.
- **Cloud Router**: a regional GCP resource that maintains BGP sessions to the router appliance instances.
Routes learned via BGP are propagated into the VPC route table as dynamic routes.

### Cloud Router Interface Design

The Cloud Router has exactly **2 interfaces** (HA pair):

- **Primary** (`{cluster}-cr-if-0`): first interface on the worker subnet.
- **Redundant** (`{cluster}-cr-if-1`): second interface, references the primary via `redundant_interface`.

Each worker peers with **both** interfaces, yielding **2 BGP sessions per worker**.
For N workers, the Cloud Router has **2N BGP peers**.

Interface IPs are either:

- Auto-allocated: `cidrhost(worker_subnet, offset)` and `cidrhost(worker_subnet, offset+1)`.
- Explicit: `router_interface_private_ips` variable (exactly 2 elements).
- Reserved: `google_compute_address` (INTERNAL) prevents other GCE resources from claiming them.

### NCC Spoke Instance Limit

**Critical constraint**: each NCC spoke supports a maximum of **8 linked router appliance instances** ([NCC limits](https://cloud.google.com/network-connectivity/docs/network-connectivity-center/quotas)).
This is a system limit and cannot be increased.

| Cluster size | Spokes required | Notes |
|-------------|-----------------|-------|
| 1-8 workers | 1 spoke | Current design works as-is |
| 9-16 workers | 2 spokes | Controller creates `{prefix}-0` and `{prefix}-1` |
| 17-24 workers | 3 spokes | Additional numbered spokes as needed |

A single NCC hub can host multiple spokes.
The number of router appliance spokes per project per region is a project quota (adjustable), not a hard limit.
The operator **shards** workers across numbered spokes and removes stale spokes when the cluster shrinks.

### Firewalls

| Rule | Source | Destination | Protocol | Purpose |
|------|--------|-------------|----------|---------|
| `{cluster}-worker-subnet-to-cudn` | Worker subnet CIDR | CUDN CIDR | Configurable (`all` / `e2etest` / `none`) | VPC hosts reaching CUDN pods |
| `{cluster}-bgp-worker-subnet` | Worker subnet CIDR | Worker subnet CIDR (or tagged instances) | TCP/179 | BGP sessions between Cloud Router and workers |

### ASN Allocation

| Component | ASN | Notes |
|-----------|-----|-------|
| Cloud Router | `64512` (default) | RFC 6996 private; required by GCP Terraform provider |
| FRR on workers | `65003` (default) | RFC 6996 private; must differ from Cloud Router ASN |

---

## OpenShift Architecture Details

### FRR Operator

Enabled via `Network.operator.openshift.io` patch.
Creates the `openshift-frr-k8s` namespace and deploys the FRR-K8s daemon on **all nodes** (not just those matching `FRRConfiguration` CRs).
FRR-K8s shares its deployment with MetalLB if both are enabled.
`FRRConfiguration` CRs in `openshift-frr-k8s` namespace configure which nodes establish BGP sessions and with which neighbors.

### FRRConfiguration Per Node

The operator creates one `FRRConfiguration` per worker:

- **Name**: `bgp-{instance-name}` (sanitized, max 50 chars).
- **`nodeSelector`**: `kubernetes.io/hostname: {node-name}` (single-node targeting).
- **Neighbors**: both Cloud Router interface IPs, with `toReceive.allowed.mode: all` and **`disableMP: true`**. MetalLB/frr-k8s may warn that the field is deprecated, but **OVN-K `RouteAdvertisements`** rejects neighbors when **`DisableMP`** is false or omitted (serialized false), with **`Not Accepted: DisableMP==false not supported`** — so the operator must set **`true`** for CUDN prefix merge and GCP learned routes.
- **`spec.raw`**: `neighbor {cr-ip} disable-connected-check` for each neighbor (required because GCP workers use `/32` on `br-ex`).

### RouteAdvertisements

```yaml
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  nodeSelector: {}
  frrConfigurationSelector: {}
  advertisements:
    - PodNetwork
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            advertise: "true"
```

- **`nodeSelector: {}`** is mandatory when `PodNetwork` is in `advertisements` (OVN-K admission rejects non-empty selectors).
- **`frrConfigurationSelector: {}`** matches all FRR configs (controller-managed and OVN-K generated).
- Only CUDNs labeled `advertise: "true"` are selected.
- OVN-K generates one `FRRConfiguration` per network and per node from this CR with appropriate advertised prefixes.
- **Receive-side route filtering is NOT applied** in OVN-K generated CRs — configure `toReceive` on the operator's `FRRConfiguration` CRs instead.

### CUDN Configuration

- **Topology**: Layer2 (single broadcast domain across all nodes via Geneve overlay).
- **Subnet**: `10.100.0.0/16` (configurable via `cudn_cidr`).
- **IPAM lifecycle**: Persistent (pod/VM IPs survive rescheduling, reboots, and live migration).
- **Namespace binding**: `namespaceSelector.matchLabels.cluster-udn: prod`.
- **Name length**: should be 15 characters or fewer for VRF device name matching in FRR.

### VM-Specific Considerations

When the workload is a KubeVirt VM rather than a pod:

- **Binding**: VMs attach to a primary Layer2 UDN via **`l2bridge`** binding (direct L2 connection to the UDN's virtual switch).
- **Live migration**: requires Layer2 topology + `ipam.lifecycle: Persistent` + **RWX PVCs**. A dedicated migration network is recommended.
- **Limitations on primary UDN**: `virtctl ssh`, `oc port-forward`, and headless services are not available.
- **`virtctl console`**: the web UI opens the serial console through the **OpenShift console** (different path than the CLI). **`virtctl`** opens a **WebSocket** to the **Kubernetes API** aggregated subresource (`.../virtualmachineinstances/.../console`). If **`virtctl version`** already matches the cluster but you still see **`Can't connect to websocket (404)`** / **bad handshake**:
  - **HTTP(S) proxy**: if **`HTTP_PROXY`**, **`HTTPS_PROXY`**, or **`http_proxy`**, **`https_proxy`** are set, the upgrade request may be sent through a proxy that does not support WebSockets and returns **404**. Unset them for that shell, or extend **`NO_PROXY`** / **`no_proxy`** to include the API server host from **`oc whoami --show-server`** (parse the hostname; add **`.svc`** / cluster-internal hosts only if your client talks to them).
  - **`proxy-url` in kubeconfig**: some **virtctl** releases ignored **`clusters[].cluster.proxy-url`** for console WebSockets; **`HTTPS_PROXY`** (or a newer **virtctl**) may behave differently — see [kubevirt#12808](https://github.com/kubevirt/kubevirt/issues/12808).
  - **Aggregation**: **`oc get apiservice | grep subresources.kubevirt.io`** should show **AVAILABLE=True**; if not, fix **openshift-cnv** / **virt-api** before expecting **virtctl** console to work.
  - **Client/server version mismatch (`vm/` prefix)**: **`virtctl` ≥ 1.8.x** with **`vm/VM_NAME`** embeds the literal string `vm/VM_NAME` as the VMI name in the URL path (e.g. `.../virtualmachineinstances/vm/VM_NAME/console`), which returns **404** from a **KubeVirt 1.7.x** server that has no such VMI. Always use **`vmi/`**: **`virtctl console vmi/VM_NAME -n NAMESPACE`**. For **`virtctl ssh`** the `type/name` format is mandatory in 1.8.x — use **`virtctl ssh cloud-user@vmi/VM_NAME -n NAMESPACE`**.
  - **Fallback**: use the **web console** VM serial console, or follow current Red Hat docs for **accessing virtual machines** (advanced options such as **virt-launcher** exec vary by CNV version).
- **Default pod network disruption**: the masquerade binding on the default pod network **interrupts traffic during live migration** — this is why CUDN is used.
- **EgressIP**: advertising EgressIPs from a Layer2 CUDN is **not supported**.

---

## Design Decisions

### All workers as BGP peers (not a subset)

**Decision**: every node in the **candidate pool** is a BGP peer (default: all workers with `node-role.kubernetes.io/worker`, excluding infra).

**Rationale**: pods can be scheduled on any such worker.
A worker without a Cloud Router BGP session cannot route CUDN egress traffic to VPC destinations.
The "router node subset" model only works if CUDN pods are guaranteed to land on router nodes (via scheduling constraints), which adds operational complexity.

**Implementation**: the reconciler uses **all** discovered candidates; optional narrowing uses **`spec.nodeSelector.labelKey`** / **`spec.nodeSelector.labelValue`** in the `BGPRoutingConfig` CR so cluster admins can limit which machine pools participate (for example, bare-metal-only BGP while other workers run non-CUDN workloads).

**Trade-off**: more GCP API calls per reconciliation cycle, more Cloud Router peers.
BGP overhead is minimal for the expected cluster sizes (6-20 workers = 12-40 peers).

### Per-node FRRConfiguration (not a single shared CR)

**Decision**: one `FRRConfiguration` CR per worker, targeting a single node via `kubernetes.io/hostname`.

**Rationale**: enables precise lifecycle management.
When a worker is removed, the controller deletes only that node's CR.
GCP-specific `spec.raw` (disable-connected-check) is the same for all nodes, but per-node CRs provide isolation if future customization is needed.

**Alternative considered**: single CR with `nodeSelector` matching a label (AWS reference pattern).
This is simpler but provides less granular control over the CR lifecycle.

### Operator-managed dynamic resources (not Terraform)

**Decision**: NCC spokes, Cloud Router BGP peers, `canIpForward`, and `FRRConfiguration` CRs are managed by the operator, not Terraform.

**Rationale**: worker node membership is dynamic (scaling, upgrades, replacements).
Terraform's plan/apply cycle is too slow for reacting to node events.
The operator watches Kubernetes nodes and reconciles within seconds.

### Layer2 CUDN topology

**Decision**: Layer2 with a `/16` subnet.

**Rationale**: all pods on the CUDN share a single L2 broadcast domain.
OVN handles inter-node L2 forwarding transparently.
BGP only needs to advertise one prefix (`10.100.0.0/16`), keeping the routing table simple.

---

## Comparison with AWS Reference (`references/rosa-bgp`)

| Aspect | GCP (this repo) | AWS (rosa-bgp reference) |
|--------|-----------------|--------------------------|
| **BGP anchor** | NCC Hub + Cloud Router (2 interfaces) | VPC Route Server (2 endpoints per subnet) |
| **Which nodes peer** | All non-infra workers (controller-managed) | 3 dedicated bare-metal pools, one per AZ |
| **FRR config** | Per-node `FRRConfiguration` CR | Single CR, `nodeSelector: bgp_router=true` |
| **FRR neighbors per node** | 2 (Cloud Router interface IPs) | 6 (all Route Server endpoint IPs listed, though only 2 per AZ are relevant) |
| **IP forwarding** | `canIpForward` on GCE instance (API) | Source/dest check disable on ENI (CLI script) |
| **Route propagation** | Cloud Router injects dynamic routes into VPC | Route Server propagates to subnet route tables |
| **Active path model** | **ECMP** (all equal-MED next-hops active simultaneously) | Single active (one next-hop in FIB at a time) |
| **Failover** | Cloud Router BGP timers | BGP keepalive (BFD not working) |
| **Cross-VPC** | Not in scope (peering / Interconnect) | Transit Gateway with static routes for CUDN CIDR |
| **Test automation** | `make bgp.e2e` (scripted) | Manual QE checklist (`tests/test-plan.md`) |
| **Node lifecycle** | Controller reconciles on Node watch events | Terraform `wait_for_instance` + manual scripts |

---

## Scaling Considerations

| Dimension | Limit | Current default | Notes |
|-----------|-------|-----------------|-------|
| **Cloud Router BGP peers** | **128** per Cloud Router (system limit) | 12 (6 workers x 2) | Supports up to **64 workers** |
| **NCC spoke instances** | **8** per spoke (system limit) | 6 | **>8 workers requires multiple spokes** |
| **NCC spokes per project/region** | Project quota (adjustable) | `ceil(workers/8)` | Request quota increase for very large clusters |
| **Learned route prefixes** | 5,000 per BGP peer | 1 (`10.100.0.0/16`) | Not a concern |
| **FRRConfiguration CRs** | No hard limit | = worker count | One per node; merged with OVN-K generated CRs |
| **Reconciliation latency** | N/A | Seconds (event-driven + 5s debounce) | Adequate for node add/remove at moderate scale |

The **8-instance NCC spoke limit** is the binding constraint for the all-workers design.
For the current default of 6 workers, this is not an issue.
For clusters scaling beyond 8 workers, the controller distributes instances across multiple numbered spokes automatically.

---

## Deployment Flow

```text
1. terraform apply (cluster_bgp_routing/)
   ├── WIF configuration
   ├── VPC + OSD cluster
   ├── NCC hub
   ├── Cloud Router + 2 interfaces + IP reservations
   ├── Firewalls (CUDN + BGP)
   └── Echo VM (optional)

2. oc login

3. configure-routing.sh (one-time)
   ├── Enable FRR operator
   ├── Create CUDN namespace
   ├── Create ClusterUserDefinedNetwork
   └── Create RouteAdvertisements

4. make bgp.deploy-operator
   ├── controller_gcp_iam/ (GCP SA + WIF)
   ├── WIF credential Secret
   ├── CRDs (BGPRoutingConfig, BGPRouter)
   ├── Operator RBAC + Deployment
   ├── BGPRoutingConfig CR (from terraform output)
   ├── In-cluster image build (or GHCR prebuilt)
   └── Deployment rollout

5. Operator reconciles (continuous)
   ├── Labels all workers (**`routing.osd.redhat.com/bgp-router`**)
   ├── Enables canIpForward on all workers; annotates nodes (**`routing.osd.redhat.com/gcp-can-ip-forward`**, nested virt when enabled)
   ├── Creates/updates NCC spokes ({prefix}-0, …)
   ├── Creates/updates Cloud Router BGP peers
   ├── Creates/updates FRRConfiguration CRs
   └── Updates BGPRouter status objects per node

6. make bgp.e2e (validation)
   ├── Deploy test pods (CUDN namespace)
   ├── Pod → Echo VM (ping + curl)
   └── Echo VM → Pod (ping + curl)
```

---

## File Map

| Path | Role |
|------|------|
| `modules/osd-bgp-routing/` | Reusable Terraform module: NCC hub, Cloud Router, interfaces, firewalls |
| `cluster_bgp_routing/` | Reference root: composes VPC + cluster + BGP module |
| `cluster_bgp_routing/scripts/configure-routing.sh` | One-time OpenShift setup (FRR, CUDN, RouteAdvertisements) |
| `operator/` | BGP routing operator (Operator SDK, CRD-based) |
| `operator/internal/reconciler/` | Core reconciliation: node discovery, label sync, multi-spoke NCC, Cloud Router peers, FRR CRs |
| `operator/internal/gcp/` | GCP API: `canIpForward`, NCC spokes, Cloud Router peers |
| `operator/internal/frr/` | Build `FRRConfiguration` CR bodies (unstructured) |
| `operator/api/v1alpha1/` | CRD types: `BGPRoutingConfig`, `BGPRouter` |
| `operator/deploy/` | OpenShift deploy manifests (namespace, RBAC, deployment, imagestream, buildconfig) |
| `controller_gcp_iam/` | Operator GCP SA + WIF IAM |
| `modules/osd-bgp-controller-iam/` | Reusable module: custom role, SA, WIF binding |
| `scripts/` | Orchestration: `bgp-apply.sh`, `bgp-deploy-operator-incluster.sh`, `e2e-cudn-connectivity.sh` |
| `archive/controller/` | Archived legacy Go + Python controllers (replaced by operator) |
| `references/rosa-bgp/` | AWS ROSA reference implementation (cloned) |
| `references/fix-bgp-ra.md` | CUDN ingress debugging plan (Phase 1-5) |
| `KNOWLEDGE.md` | Verified facts and unverified assumptions |
