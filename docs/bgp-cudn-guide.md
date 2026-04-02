# A Practical Guide to BGP and CUDN Routing on OpenShift

A ground-up explanation of how BGP, User-Defined Networks, and cloud routing fit together to give KubeVirt VMs stable, routable IPs on managed OpenShift clusters.
No prior BGP or networking knowledge is assumed.

---

## Part 1: Core Concepts

### The Problem in Plain English

When you run a virtual machine (VM) inside an OpenShift cluster using KubeVirt, OpenShift gives that VM an internal IP address.
By default, that IP is only meaningful *inside* the cluster.
If a machine outside the cluster (say, a database server sitting in your cloud VPC) wants to talk directly to that VM, it has no idea how to reach the VM's internal IP.
The cluster's internal addresses are invisible to the outside world.

OpenShift's default behavior makes this worse in two ways:

1. **NAT on egress**: when traffic leaves the cluster, OpenShift rewrites the source IP to the *worker node's* IP (this is called SNAT — Source Network Address Translation).
   The VM's real IP is hidden.
   The destination server sees the node IP, not the VM.
2. **Traffic interruption during live migration**: KubeVirt can move a running VM from one worker node to another (live migration).
   On the default pod network, traffic is **interrupted** during this move because the masquerade (NAT) binding has to be re-established on the new node.

For workloads that need stable, directly-routable IPs that survive live migration without interruption, the default pod network is not enough.

### What is a User-Defined Network (UDN)?

OpenShift's networking layer (OVN-Kubernetes, or "OVN-K") provides a **default pod network** that every pod and VM is connected to.
This is the "out-of-the-box" network.

A **User-Defined Network (UDN)** is a second, separate network that you create alongside the default one.
Think of it as a private VLAN within the cluster.
Pods or VMs attached to a UDN get an IP from a subnet you choose (for example, `10.100.0.0/16`), completely independent of the default pod network.

A **Cluster User-Defined Network (CUDN)** is a UDN that spans the entire cluster (or a set of namespaces), rather than being confined to a single namespace.
The "C" just means "cluster-scoped."

A typical CUDN for this use case has these properties:

| Property | Value | Why |
|----------|-------|-----|
| **Topology** | Layer2 | All pods/VMs share one flat broadcast domain across nodes, connected by an overlay (Geneve tunnels). Recommended for VMs on public clouds. |
| **Subnet** | `10.100.0.0/16` | A private range with room for ~65,000 IPs. Chosen to not overlap with the VPC's CIDR. |
| **IPAM lifecycle** | Persistent | IPs are preserved across reboots and live migration. Without this, a migrated VM gets a new IP. |
| **Isolation** | Strict (default) | Pods on different CUDNs cannot talk to each other. Hosts outside the CUDN (including `oc debug node`) also cannot reach CUDN IPs directly. |

With a CUDN, your VM gets an IP like `10.100.0.42`, and that IP stays the same even if the VM is live-migrated to a different worker node.
But there is still a problem: the VPC (the cloud network surrounding the cluster) does not know how to route traffic to `10.100.0.0/16`.
As far as the cloud is concerned, that subnet does not exist.

**This is where BGP comes in.**

### What is BGP?

**BGP** (Border Gateway Protocol) is how networks on the internet tell each other which IP ranges they can reach.
When you visit a website, your ISP uses BGP to figure out which network to send your traffic to.
It is the "postal routing system" of the internet.

At its core, BGP is simple:

1. Two routers establish a **BGP session** (a persistent TCP connection on port 179).
2. Each router **advertises** the IP prefixes (ranges) it can reach.
   For example: "I can reach `10.100.0.0/16`."
3. The other router adds that to its **routing table** — now it knows to forward traffic for `10.100.0.0/16` to the first router.
4. Routes can be **withdrawn** if a router goes down or a prefix is no longer reachable.

Some vocabulary:

| Term | Meaning |
|------|---------|
| **Prefix** | An IP range, written in CIDR notation (e.g., `10.100.0.0/16`). |
| **Peer** | A router you have a BGP session with. |
| **ASN** (Autonomous System Number) | A unique ID for each "side" of a BGP session. Each organization or network gets its own. Private ASNs (64512-65534) are used for internal/private networks. |
| **eBGP** | External BGP — peering between two different ASNs. OpenShift workers and the cloud router have different ASNs, so they use eBGP. |
| **Advertise** | Announce to your peer: "I can reach this prefix." |
| **Learned route** | A route your router received from a peer. |
| **ECMP** | Equal-Cost Multi-Path — when multiple paths to the same prefix have the same cost, traffic is distributed across all of them. |
| **MED** | Multi-Exit Discriminator — a BGP attribute that influences which path a peer prefers. When all MEDs are equal, ECMP kicks in. |
| **Hold timer** | How long a router waits without hearing from a peer before declaring it dead (typically 90 seconds). |

### What is FRR?

**FRR** (Free Range Routing) is an open-source routing software suite that runs on Linux.
It can speak BGP (and other protocols like OSPF).

In OpenShift, FRR runs as a **daemon on every worker node** via the **FRR-K8s** operator.
Each worker node becomes a small router capable of establishing BGP sessions, advertising prefixes, and learning routes.

FRR is configured through Kubernetes custom resources called **`FRRConfiguration`** CRs.
Each CR specifies:

- Which node it applies to (via `nodeSelector`).
- Which BGP neighbors (peers) to connect to.
- What routes to accept from those peers.
- Any raw FRR configuration needed for edge cases.

Multiple `FRRConfiguration` CRs targeting the same node are **merged** by the FRR-K8s admission controller.
This is important because OVN-K *also* generates its own FRR CRs (named `ovnk-generated-*`) for route advertisement.

### How FRR Gets Enabled

FRR is not enabled by default.
It is turned on by patching the OpenShift `Network.operator.openshift.io` object:

```json
{
  "spec": {
    "additionalRoutingCapabilities": {
      "providers": ["FRR"]
    },
    "defaultNetwork": {
      "ovnKubernetesConfig": {
        "routeAdvertisements": "Enabled"
      }
    }
  }
}
```

This does two things:

1. Deploys the **FRR-K8s daemon** on **all nodes** (not just the ones you want to be BGP routers).
2. Enables the **RouteAdvertisements** API, which tells OVN-K to generate FRR configs that advertise CUDN prefixes.

### What is a RouteAdvertisement?

A **RouteAdvertisement** is an OpenShift custom resource that tells OVN-K:

> "Take the pod IPs from these specific user-defined networks and make sure FRR advertises them to any configured BGP peers."

Here is an example:

```yaml
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  advertisements:
    - PodNetwork
  nodeSelector: {}
  frrConfigurationSelector: {}
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            advertise: "true"
```

Breaking this down:

- **`advertisements: [PodNetwork]`** — advertise the pod network prefixes (the CUDN subnet).
- **`nodeSelector: {}`** — apply to all nodes.
  This is **mandatory** when `PodNetwork` is selected; OVN-K's admission webhook rejects any non-empty selector.
  The logic: "if you are advertising the pod network, it must be advertised from everywhere."
- **`frrConfigurationSelector: {}`** — match all FRR configurations.
- **`networkSelectors`** — only advertise CUDNs labeled `advertise: "true"`.

OVN-K processes this CR and auto-generates one `FRRConfiguration` per node per selected network.
These generated CRs handle the "outbound advertisement" side: telling peers what prefixes this node can reach.
They do **not** configure which peers to connect to or what routes to accept — that is the job of separately managed `FRRConfiguration` CRs that you (or an automation controller) create to add your cloud router as a BGP neighbor.

### Putting It Together: The Full Picture

Here is how all the pieces connect:

```text
                    Cloud / VPC
                         │
                         │  "Where is 10.100.0.0/16?"
                         ▼
                  ┌──────────────┐
                  │ Cloud Router │  ← learns routes via BGP
                  │  ASN 64512   │
                  └──────┬───────┘
                         │
              BGP sessions (TCP/179)
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
    ┌──────────┐   ┌──────────┐   ┌──────────┐
    │ Worker 1 │   │ Worker 2 │   │ Worker 3 │
    │ FRR      │   │ FRR      │   │ FRR      │
    │ ASN 65003│   │ ASN 65003│   │ ASN 65003│
    │          │   │  ┌─────┐ │   │  ┌─────┐ │
    │          │   │  │VM A │ │   │  │VM B │ │
    │          │   │  └─────┘ │   │  └─────┘ │
    └──────────┘   └──────────┘   └──────────┘
           OVN Layer2 overlay (10.100.0.0/16)
```

1. Every worker runs FRR (ASN 65003) and has BGP sessions with the Cloud Router (ASN 64512).
2. Every worker **advertises** `10.100.0.0/16` to the Cloud Router: "I can reach this network."
3. The Cloud Router **learns** the route and injects it into the VPC routing table: "To reach `10.100.0.0/16`, send traffic to these workers."
4. Every worker **receives** VPC routes from the Cloud Router: "To reach `10.0.0.0/16` (the VPC), send traffic to me."
5. A VPC host wanting to reach `10.100.0.42` sends the packet. The VPC route table points it at one of the workers.
   If the pod happens to be on that worker, great — delivered locally.
   If not, OVN forwards it through the Layer2 overlay to the correct node.
6. When VM A sends traffic *out* to the VPC, FRR on its worker has learned the VPC route from the Cloud Router, so the worker knows where to forward it.
   The source IP is **preserved** (no SNAT) — the destination sees `10.100.0.42`, not the worker's node IP.

### Why Every Worker Needs BGP

It is tempting to designate only a few "router nodes" as BGP peers and assume the OVN overlay will forward traffic between routers and pods on other nodes.
In practice, this does not work:

- **Outbound breaks on non-peered nodes**: FRR runs on every node (once enabled), but without a cloud router neighbor configured, FRR has no BGP session and learns no routes.
  A VM on a non-peered node tries to send traffic to the VPC — the node's routing table has no path for it, and the packet is dropped.
- **Inbound can also fail**: traffic from the VPC can only arrive at nodes the cloud router knows about (the BGP peers).
  The OVN overlay *should* forward the packet to the correct node, but this forwarding path for externally-sourced traffic entering via the host network is not always reliable.

The robust approach is to **make every worker node a BGP peer**.
Every node gets a `FRRConfiguration` CR adding the cloud router as a neighbor.
Every node learns VPC routes and can route CUDN egress traffic.
Every node advertises the CUDN prefix and can receive inbound traffic directly.

This eliminates the scheduling dependency: pods and VMs can land on any worker without worrying about whether that worker has connectivity to the outside world.

### Platform Support: A Note on "Bare Metal Only"

The OpenShift documentation states that BGP routing and route advertisements are supported on **bare-metal infrastructure** only.
This language describes Red Hat's **support boundary** — the configurations they will officially support — not a technical limitation.

BGP works on cloud VM workers in practice.
AWS deployments often use `c5.metal` instances (which are technically bare-metal on AWS), while GCP deployments use standard VM workers.
Both work.
Operating outside the documented support matrix may be an acceptable trade-off depending on your use case and support requirements.

---

## Part 2: GCP-Specific Details

### How GCP Learns Routes from Your Cluster

On bare-metal or in a data center, you would point your BGP router directly at the worker nodes.
In GCP, you cannot do this directly — GCP's virtual network does not support running arbitrary BGP peers on the VPC fabric.
Instead, GCP provides a framework called **Network Connectivity Center (NCC)** with a pattern called **Router Appliance**.

The Router Appliance model works like this:

1. You tell GCP: "These GCE instances are acting as routers."
2. GCP's **Cloud Router** establishes BGP sessions with those instances.
3. Routes learned via BGP from those instances are injected into the VPC routing table.

There are three GCP resources involved:

| Resource | What it is | Analogy |
|----------|-----------|---------|
| **NCC Hub** | A global container that organizes routing connections. One per setup. | The main switchboard |
| **NCC Spoke** | A regional resource that links specific GCE instances (as "router appliances") to the hub. | A cable connecting routers to the switchboard |
| **Cloud Router** | A regional GCP resource that maintains BGP sessions with the router appliances and propagates learned routes into VPC route tables. | The cloud-side BGP peer |

### Cloud Router: The Two-Interface HA Design

The Cloud Router has exactly **2 interfaces**, configured as an HA (high availability) pair:

- **Primary** interface
- **Redundant** interface (references the primary for HA failover)

Each worker node peers with **both** interfaces — that is 2 BGP sessions per worker.
If one interface fails, sessions on the other remain active.

For a cluster with N workers, the Cloud Router has **2N BGP peers** total.
GCP supports up to **128 BGP peers** per Cloud Router, so this design supports clusters of up to **64 workers**.

The interface IPs are reserved as `google_compute_address` (INTERNAL) resources to prevent other GCE instances from claiming them.

### ASN Allocation

BGP requires each side to have a unique ASN (Autonomous System Number):

| Component | ASN | Range |
|-----------|-----|-------|
| Cloud Router | `64512` | RFC 6996 private range (required by GCP) |
| FRR on workers | `65003` | RFC 6996 private range (must differ from Cloud Router) |

These are **eBGP** sessions (External BGP) because the two sides have different ASNs.

### The `/32` Problem and `disable-connected-check`

GCP assigns worker nodes a `/32` address on their external bridge interface (`br-ex`).
A `/32` means the address has no subnet — the node "owns" only its single IP, with no directly-connected neighbors.

This causes a subtle BGP problem: FRR, by default, expects its BGP neighbor to be on a directly-connected subnet.
When FRR tries to establish a session with the Cloud Router interface IP, it sees that the neighbor is not on any connected network (because `/32` has no neighbors).
The TCP connection to port 179 succeeds (GCP's fabric routes it), but FRR refuses to proceed with the BGP session — it stays stuck in `Active` state.

The fix is a raw FRR configuration directive:

```text
neighbor 10.0.x.x disable-connected-check
```

This tells FRR: "trust me, this neighbor is reachable even though it is not on a connected subnet."
This directive is added to the `FRRConfiguration` CR's `spec.raw` section for each Cloud Router neighbor.

A note on alternatives: the `ebgpMultiHop` field on typed neighbors solves a similar problem, but MetalLB's admission controller rejects it when the CR is merged with OVN-K generated FRR CRs.
The raw `disable-connected-check` directive avoids this conflict.

### `canIpForward`: Enabling IP Forwarding

By default, GCP drops any packet arriving at a VM if the destination IP does not match the VM's own IP.
This is a security feature to prevent VMs from acting as routers.

For CUDN routing to work, workers must forward packets destined for CUDN IPs (like `10.100.0.42`) that may belong to pods on other nodes.
The GCE instance property **`canIpForward`** must be set to `true` on each worker.

This can be set at instance creation time or updated afterward via the GCE API.
In an automated setup, a controller or script enables `canIpForward` on each worker as it joins the cluster.

The AWS equivalent is disabling **source/destination checking** on the EC2 instance's network interface.

### NCC Spoke: The 8-Instance Limit

Each NCC spoke can link a maximum of **8 router appliance instances**.
This is a GCP system limit that cannot be increased.

| Cluster size | Spokes needed | Notes |
|-------------|---------------|-------|
| 1-8 workers | 1 | Simplest configuration |
| 9-16 workers | 2 | Automation must distribute workers across spokes |
| 17-24 workers | 3 | Requires spoke-assignment logic |

A single NCC hub can host multiple spokes, and the spoke count per project and region is an adjustable quota (not a hard limit).
For most managed OpenShift cluster sizes (6-20 workers), 1-3 spokes are sufficient.
Any automation managing NCC spokes needs to account for this limit when clusters grow beyond 8 workers.

### ECMP: How GCP Distributes Traffic

When multiple router appliances advertise the same prefix with the same MED (Multi-Exit Discriminator), GCP Cloud Router uses **ECMP** (Equal-Cost Multi-Path) routing.
This means inbound traffic is distributed across **all** peered workers, not sent to just one.

The distribution is based on a **5-tuple hash** (source IP, destination IP, source port, destination port, protocol).
For a given flow (e.g., a TCP connection), the hash is deterministic — it always selects the same worker.
Different flows may land on different workers.

With N workers:

- There is a `1/N` chance the packet lands on the worker that hosts the target pod — delivered locally.
- Otherwise, the receiving worker forwards the packet through the OVN Layer2 overlay to the correct node.

This is **different from AWS Route Server**, which uses single-active routing: only one next-hop is installed in the subnet route tables at a time.
GCP's ECMP approach provides:

- **Better load distribution**: traffic spreads across all workers.
- **Faster failover**: when a worker goes down, Cloud Router removes it from the ECMP set (after the BGP hold timer expires) rather than needing a full route table swap.

### The Data Plane: Following a Packet

#### Inbound: VPC host to a CUDN VM

```text
1. VPC Host (10.0.1.5) sends a packet to CUDN VM (10.100.0.42)

2. VPC route table lookup:
   10.100.0.0/16 → [Worker 1, Worker 2, Worker 3, ...] (ECMP)
   5-tuple hash selects Worker 2

3. Packet arrives at Worker 2 (canIpForward=true)

4. Is 10.100.0.42 on Worker 2?
   YES → OVN delivers locally
   NO  → OVN forwards via Layer2 overlay to the correct worker

5. VM receives the packet with its original destination IP
```

#### Outbound: CUDN VM to a VPC host

```text
1. VM (10.100.0.42) on Worker 3 sends a packet to VPC Host (10.0.1.5)

2. OVN Layer2 network hands the packet to the host network stack

3. Worker 3's routing table (populated by FRR from BGP-learned routes):
   10.0.0.0/16 → Cloud Router interface IP
   Packet is forwarded to Cloud Router

4. Cloud Router delivers the packet to VPC Host (10.0.1.5)

5. Source IP is 10.100.0.42 (preserved — no SNAT)
```

#### Intra-CUDN: VM to VM

```text
1. VM A (10.100.0.10 on Worker 2) sends to VM B (10.100.0.11 on Worker 5)

2. OVN Layer2 overlay handles this directly — same broadcast domain
   Traffic goes through the Geneve tunnel between Worker 2 and Worker 5

3. No BGP involvement. Works regardless of BGP peering.
```

### Firewalls

Two GCP firewall rules are needed:

| Rule | Traffic allowed | Purpose |
|------|----------------|---------|
| Worker-to-CUDN | Worker subnet CIDR → CUDN CIDR | VPC hosts reaching CUDN pods/VMs |
| BGP peering | Worker subnet CIDR ↔ Cloud Router IPs, TCP/179 | BGP sessions between Cloud Router interfaces and workers |

Without the BGP firewall rule, the TCP connection to port 179 is blocked and no BGP sessions can form.

### Static vs. Dynamic Resources

A useful mental model is to separate the GCP resources into two categories:

| Category | Resources | Lifecycle |
|----------|-----------|-----------|
| **Static** | NCC hub, Cloud Router, Cloud Router interfaces, IP reservations, firewalls | Created once during initial setup; rarely changes |
| **Dynamic** | NCC spoke memberships, Cloud Router BGP peers, `canIpForward` on instances, `FRRConfiguration` CRs | Must be updated whenever workers are added, removed, or replaced |

Static resources are good candidates for infrastructure-as-code tools (Terraform, Pulumi, etc.).
Dynamic resources need to react to cluster events — node scaling, upgrades, replacements — and are better managed by an in-cluster controller or operator that watches Kubernetes node events and reconciles GCP state in near real-time.

The key operations that must happen whenever a worker node joins or leaves:

1. **Enable `canIpForward`** on the new GCE instance.
2. **Add the instance to an NCC spoke** (respecting the 8-instance limit).
3. **Create 2 Cloud Router BGP peers** (one per interface) pointing at the new worker.
4. **Create a `FRRConfiguration` CR** targeting the new node with the Cloud Router interface IPs as neighbors.
5. **Clean up** stale peers, spoke entries, and FRR CRs when a worker is removed.

---

## Part 3: AWS-Specific Details

### How AWS Learns Routes from Your Cluster

AWS provides **VPC Route Server**, a managed service that accepts BGP sessions from EC2 instances and propagates learned routes into VPC subnet route tables.
It plays the same role as GCP's Cloud Router + NCC combination but is a single, simpler resource.

The Route Server model works like this:

1. You create a **VPC Route Server** and associate it with your VPC.
2. You deploy **Route Server endpoints** in the private subnets where your worker nodes live — 2 endpoints per subnet.
3. You create **Route Server peers** linking each worker node to the endpoints in its subnet.
4. FRR on each worker establishes BGP sessions with those endpoints and advertises the CUDN prefix.
5. Route Server learns the routes and **propagates** them into the VPC's subnet route tables.

| Resource | What it is | Analogy |
|----------|-----------|---------|
| **VPC Route Server** | A managed BGP route reflector for your VPC. One per setup. | The central exchange point |
| **Route Server Endpoint** | A network interface in a specific subnet that workers peer with. 2 per subnet, 6 total across 3 AZs. | A local access point in each AZ |
| **Route Server Peer** | A BGP peering relationship between a worker node and a Route Server endpoint. | The cable connecting a router to the exchange |

### The Multi-AZ Endpoint Layout

A typical ROSA (Red Hat OpenShift Service on AWS) deployment uses 3 Availability Zones, each with a private subnet.
Route Server deploys **2 endpoints per private subnet** — 6 endpoints total.

Each router worker peers with the **2 endpoints in its own subnet**.
This keeps BGP traffic local to the AZ and avoids cross-AZ data transfer costs.

```text
┌────────────────────────────────────────────────────────────────┐
│                        AWS VPC                                  │
│                                                                 │
│    AZ-a (subnet-1)      AZ-b (subnet-2)      AZ-c (subnet-3)  │
│   ┌──────────────┐    ┌──────────────┐     ┌──────────────┐    │
│   │ RS EP 1      │    │ RS EP 3      │     │ RS EP 5      │    │
│   │ RS EP 2      │    │ RS EP 4      │     │ RS EP 6      │    │
│   │              │    │              │     │              │    │
│   │ ┌──────────┐ │    │ ┌──────────┐ │     │ ┌──────────┐ │    │
│   │ │ Worker 1 │ │    │ │ Worker 2 │ │     │ │ Worker 3 │ │    │
│   │ │ FRR      │ │    │ │ FRR      │ │     │ │ FRR      │ │    │
│   │ │ peers:   │ │    │ │ peers:   │ │     │ │ peers:   │ │    │
│   │ │ EP1, EP2 │ │    │ │ EP3, EP4 │ │     │ │ EP5, EP6 │ │    │
│   │ └──────────┘ │    │ └──────────┘ │     │ └──────────┘ │    │
│   └──────────────┘    └──────────────┘     └──────────────┘    │
│                                                                 │
│                    ┌──────────────────┐                         │
│                    │  VPC Route Server│                         │
│                    │  ASN 65002       │                         │
│                    │  (all endpoints) │                         │
│                    └──────────────────┘                         │
└────────────────────────────────────────────────────────────────┘
```

### ASN Allocation

| Component | ASN | Notes |
|-----------|-----|-------|
| VPC Route Server | `65002` | AWS-side ASN; set at creation time |
| FRR on workers | `65003` | Must differ from Route Server ASN |

Like GCP, these are eBGP sessions between different ASNs.

### Single-Active Routing (Not ECMP)

This is the most important behavioral difference from GCP.

VPC Route Server maintains routes from **all** BGP peers in its **RIB** (Routing Information Base — the full set of known routes), but installs only **one** next-hop in the **FIB** (Forwarding Information Base — the active route tables that actually forward packets) at a time.

In plain terms: even though all three workers advertise `10.100.0.0/16`, AWS only puts **one worker's IP** into the subnet route tables.
Traffic goes to that single active worker.

If that worker goes down (detected via BGP keepalive), Route Server swaps the route table entry to point at a surviving worker.
This is **single-active with failover**, not load-balanced ECMP.

Implications:

- **All inbound traffic funnels through one worker** — that worker must forward packets via the OVN overlay to pods on other nodes.
- **Failover is automatic** but takes time (the BGP keepalive timer must expire before Route Server detects the failure).
- **No load distribution** for inbound traffic — unlike GCP's ECMP, there is no 5-tuple hashing across workers.

Despite the single-active limitation, testing has shown **zero packet loss** during worker node termination when pinging at 1-second intervals, because Route Server adjusts quickly enough.

### Source/Destination Check: AWS's IP Forwarding

By default, AWS drops packets arriving at an EC2 instance if the destination IP does not match the instance's own IP.
This is the same concept as GCP's `canIpForward`, but the mechanism is different.

On AWS, you disable **source/destination checking** on the instance's network interface (ENI).
This can be done via the AWS CLI, API, or a DaemonSet that runs on each worker and disables the check automatically.

The DaemonSet approach is particularly useful because it handles new nodes joining the cluster during scaling or upgrades without manual intervention.

### Dedicated Router Nodes

On AWS, the typical pattern uses **dedicated bare-metal machine pools** for BGP routing — one `c5.metal` instance per AZ, 3 in total.
These are separate from the default compute pool that runs general workloads.

The workers are tagged (e.g., `bgp_router=true`) and the `FRRConfiguration` CR targets them via `nodeSelector`:

```yaml
spec:
  nodeSelector:
    matchLabels:
      bgp_router: "true"
```

Using bare-metal instances (`c5.metal`) on AWS has a practical benefit: it keeps the deployment within OpenShift's documented bare-metal support boundary for BGP routing.
Bare-metal instances on AWS behave identically to regular cloud VMs from a Kubernetes perspective, but they count as "bare metal" for Red Hat support purposes.

The same principle from Part 1 applies: any node that may host CUDN workloads needs to be a BGP peer, or pods on non-peered nodes will have no outbound route for CUDN traffic.

### FRR Configuration on AWS

On AWS, a **single shared `FRRConfiguration` CR** is typically used rather than per-node CRs.
The CR targets all router nodes via a label selector and lists all 6 Route Server endpoint IPs as neighbors:

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: all-nodes
  namespace: openshift-frr-k8s
spec:
  nodeSelector:
    matchLabels:
      bgp_router: "true"
  bgp:
    routers:
    - asn: 65003
      neighbors:
      - address: <RS-subnet1-ep1-IP>
        asn: 65002
        disableMP: true
        toReceive:
          allowed:
            mode: all
      - address: <RS-subnet1-ep2-IP>
        asn: 65002
        disableMP: true
        toReceive:
          allowed:
            mode: all
      # ... (4 more endpoints, 2 per remaining subnet)
```

All 6 endpoint IPs are listed as neighbors, even though each worker only peers with the 2 in its own subnet.
FRR attempts to connect to all listed neighbors, but only the 2 that are reachable from that subnet establish sessions.
The other 4 remain in `Active` state — this is harmless.

Notable differences from GCP's FRR configuration:

- **No `disable-connected-check` needed** — AWS workers do not have the `/32` address issue that GCP has.
- **No `spec.raw` section** — the standard typed neighbor configuration works without workarounds.
- **Single CR vs. per-node** — simpler lifecycle management, but less granular control.

### Cross-VPC Routing with Transit Gateway

A common requirement on AWS is reaching CUDN VMs from a **different VPC** (e.g., an on-premises network extension or a shared-services VPC).
AWS Transit Gateway (TGW) provides this:

1. **Attach both VPCs** to the Transit Gateway.
2. **Add a static route** in the Transit Gateway route table: `10.100.0.0/16` → attachment for the ROSA VPC.
3. **Route Server propagation** handles the VPC-internal routing — the subnet route tables already know to send `10.100.0.0/16` to a router worker.

Traffic from the external VPC follows this path:

```text
External VPC (192.168.0.0/16)
  │
  ▼
Transit Gateway
  │  static route: 10.100.0.0/16 → ROSA VPC attachment
  ▼
ROSA VPC subnet route table
  │  learned route: 10.100.0.0/16 → Router Worker (via Route Server)
  ▼
Router Worker → OVN overlay → CUDN VM
```

### The Data Plane: Following a Packet on AWS

#### Inbound: EC2 instance to a CUDN VM

```text
1. EC2 instance (10.0.1.5) sends a packet to CUDN VM (10.100.0.42)

2. Subnet route table lookup:
   10.100.0.0/16 → Worker 1 (single active next-hop from Route Server)

3. Packet arrives at Worker 1 (source/dest check disabled)

4. Is 10.100.0.42 on Worker 1?
   YES → OVN delivers locally
   NO  → OVN forwards via Layer2 overlay to the correct worker

5. VM receives the packet with its original destination IP
```

All inbound traffic goes through the single active worker, which must forward most packets via the OVN overlay.

#### Outbound: CUDN VM to an EC2 instance

```text
1. VM (10.100.0.42) on Worker 2 sends a packet to EC2 instance (10.0.1.5)

2. OVN Layer2 network hands the packet to the host network stack

3. Worker 2's routing table (populated by FRR from BGP-learned routes):
   10.0.0.0/16 → Route Server endpoint IP
   Packet is forwarded to Route Server

4. Route Server delivers to the VPC fabric → EC2 instance (10.0.1.5)

5. Source IP is 10.100.0.42 (preserved — no SNAT)
```

Outbound works from **any peered worker** directly — it does not funnel through the single active worker.
Each peered worker has its own BGP sessions and learned routes.

### Static vs. Dynamic Resources

Like GCP, there is a natural split:

| Category | Resources | Lifecycle |
|----------|-----------|-----------|
| **Static** | VPC Route Server, endpoints, Transit Gateway, VPC attachments | Created once |
| **Dynamic** | Route Server peers, source/dest check disable, `FRRConfiguration` CRs | Must track worker membership |

On AWS, the source/dest check disable is often handled by a **DaemonSet** that runs on tagged worker nodes, making it self-healing for new nodes.
Route Server peers are typically created via Terraform, since dedicated machine pools with fixed replica counts change infrequently.

### Scaling Limits

| Dimension | Limit | Typical value | Notes |
|-----------|-------|---------------|-------|
| **Route Server peers per endpoint** | 20 | 3 (one per AZ) | Constrains the "all nodes as peers" approach |
| **Route Server endpoints per subnet** | 2 | 2 | Fixed; cannot be increased |
| **BGP keepalive failover** | Seconds to tens of seconds | Depends on timers | Faster than hold timer expiry |
| **BFD (Bidirectional Forwarding Detection)** | Supported but may have issues | Not used | Some deployments report BFD problems with Route Server |

The 20-peer-per-endpoint limit means AWS is more constrained than GCP for large clusters.
With 3 AZs and 1 router per AZ, each endpoint has only 1 peer — well within limits.
Scaling to many more routers per AZ would approach this ceiling.

---

## Part 4: GCP vs. AWS Comparison

| Aspect | GCP | AWS |
|--------|-----|-----|
| **Cloud BGP anchor** | NCC Hub + Cloud Router | VPC Route Server |
| **Sessions per worker** | 2 (one per Cloud Router interface) | 2 (one per Route Server endpoint in the worker's subnet) |
| **Route propagation** | Cloud Router injects dynamic routes into VPC | Route Server propagates to subnet route tables |
| **Active path model** | **ECMP** (all workers active simultaneously) | **Single active** (one next-hop in route table at a time) |
| **IP forwarding** | `canIpForward` on GCE instance | Source/dest check disable on ENI |
| **Worker type** | Standard cloud VMs | `c5.metal` bare-metal instances |
| **Max instances per group** | 8 per NCC spoke | 20 peers per Route Server endpoint |
| **Failover mechanism** | ECMP removes dead worker after hold timer | BGP keepalive triggers route table swap |
| **Cross-VPC routing** | VPC Peering or Interconnect | Transit Gateway with static routes |
| **FRR config style** | Per-node `FRRConfiguration` CRs | Single shared `FRRConfiguration` CR |
| **`disable-connected-check`** | Required (`/32` on `br-ex`) | Not needed |
| **Node management** | Dynamic (controller reconciles on node events) | Static (dedicated machine pools, Terraform) |

---

## Glossary

| Term | Definition |
|------|-----------|
| **ASN** | Autonomous System Number — a unique identifier for a network in BGP. |
| **BGP** | Border Gateway Protocol — the protocol routers use to exchange reachability information. |
| **`canIpForward`** | A GCP instance property that allows a VM to forward packets not destined for its own IP. |
| **Cloud Router** | A GCP resource that maintains BGP sessions and injects learned routes into VPC route tables. |
| **CUDN** | Cluster User-Defined Network — a UDN that spans the cluster, giving pods/VMs IPs from a dedicated subnet. |
| **eBGP** | External BGP — BGP peering between different ASNs. |
| **ECMP** | Equal-Cost Multi-Path — distributing traffic across multiple paths with equal cost. |
| **FIB** | Forwarding Information Base — the active routing table used to forward packets. On AWS, Route Server installs only one next-hop in the FIB at a time. |
| **FRR** | Free Range Routing — open-source routing software that runs on Linux and speaks BGP. |
| **FRR-K8s** | The Kubernetes operator that deploys and manages FRR on OpenShift nodes. |
| **`FRRConfiguration`** | A Kubernetes CR that configures FRR on one or more nodes (neighbors, routes, raw config). |
| **Geneve** | A network tunneling protocol used by OVN to create overlay networks between nodes. |
| **Layer2 topology** | A UDN mode where all pods share one flat broadcast domain, connected across nodes via overlay tunnels. |
| **MED** | Multi-Exit Discriminator — a BGP attribute influencing route preference. Equal MED enables ECMP. |
| **NCC** | Network Connectivity Center — GCP's framework for connecting different network environments. |
| **NCC Hub** | A global NCC resource that organizes routing connections. |
| **NCC Spoke** | A regional NCC resource linking GCE instances as router appliances to a hub. |
| **OVN-K** | OVN-Kubernetes — OpenShift's default networking implementation. |
| **Prefix** | An IP range in CIDR notation (e.g., `10.100.0.0/16`). |
| **RIB** | Routing Information Base — the full set of routes a router knows about. Route Server keeps all peers' routes in the RIB but only installs one in the FIB. |
| **RouteAdvertisements** | An OpenShift CR that tells OVN-K to have FRR advertise specific network prefixes via BGP. |
| **Route Server Endpoint** | An AWS network interface in a specific subnet that workers establish BGP sessions with. |
| **Router Appliance** | A GCP pattern where GCE instances act as routers, peering with Cloud Router via NCC. |
| **SNAT** | Source NAT — rewriting the source IP of outbound traffic (what we want to avoid). |
| **Transit Gateway (TGW)** | An AWS service that connects multiple VPCs and on-premises networks through a central hub. |
| **UDN** | User-Defined Network — a custom overlay network in OpenShift, separate from the default pod network. |
| **VPC Route Server** | An AWS managed service that accepts BGP sessions from EC2 instances and propagates learned routes into VPC subnet route tables. |
| **VRF** | Virtual Routing and Forwarding — network isolation at the routing-table level (an alternative to the Layer2 approach used here). |
