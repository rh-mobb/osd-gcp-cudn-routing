# Knowledge Base: CUDN BGP Routing on Managed OpenShift

What we know (verified) and what we think (unverified) about BGP-based CUDN routing for managed OpenShift clusters on cloud providers.

---

## Verified Facts

Facts validated through testing, documentation, code, or multiple independent sources.

### OpenShift / OVN-K Behavior

- **RouteAdvertisements with `PodNetwork` require `nodeSelector: {}`.**
OVN-K validating admission rejects any non-empty `nodeSelector` when `advertisements` includes `PodNetwork`.
The error is: `If 'PodNetwork' is selected for advertisement, a 'nodeSelector' can't be specified as it needs to be advertised on all nodes`.
Validated March 2026 on OCP; documented in `references/fix-bgp-ra.md` Phase 2.
Confirmed in OCP 4.21 Advanced Networking guide (Table 7.1): *"When advertisements='PodNetwork' is selected, all nodes must be selected."*
- **BGP routing and route advertisements are officially documented as "supported" on bare-metal infrastructure only.**
OCP 4.21 Advanced Networking guide states multiple times: *"BGP routing is supported on the following infrastructure types: Bare metal"* and *"Advertising routes with border gateway protocol (BGP) is supported on the bare-metal infrastructure type."*
This refers to Red Hat's **support boundary**, not a technical limitation — BGP works on cloud VM workers in practice.
Our OSD-GCP deployment is outside the documented support matrix, which is acceptable for this use case.
- **FRR operator is enabled via Network operator patch.**
Both GCP and AWS reference stacks enable FRR and route advertisements with the same `Network.operator.openshift.io` patch: `additionalRoutingCapabilities.providers: [FRR]` and `routeAdvertisements: Enabled`.
- **When FRR is enabled, the FRR-K8s daemon is deployed on all nodes.**
OCP 4.21 Advanced Networking guide: *"`spec.additionalRoutingCapabilities`: Enables deployment of the FRR-K8s daemon for the cluster… When enabled, the FRR-K8s daemon is deployed on all nodes."*
- **FRR-K8s and MetalLB share the same FRR deployment.**
OCP 4.21 Advanced Networking guide: *"This feature and the MetalLB Operator use the same FRR-K8s deployment."* Deploying MetalLB automatically enables FRR-K8s.
- **CUDN Layer2 topology with a `/16` subnet is the standard pattern.**
Both GCP (`10.100.0.0/16`) and AWS (`10.100.0.0/16`) reference stacks use identical Layer2 CUDN configuration with `ipam.lifecycle: Persistent`.
- **Layer2 + `ipam.lifecycle: Persistent` is required for VM live migration.**
OCP 4.21 Virtualization guide: *"You must use the OVN-Kubernetes layer 2 topology and enable persistent IP address allocation in the user-defined network (UDN) configuration to ensure VM live migration support."*
IPs are preserved *"between reboots and during live migration."*
- **Layer2 UDN is the recommended topology for VMs on public clouds (including GCP).**
OCP 4.21 Virtualization guide: *"Connecting VMs to user-defined networks with the layer2 topology is recommended on public clouds."*
Direct underlay attachment is not supported on OSD, Google Cloud, ROSA, or Azure.
- **Default pod network (masquerade) traffic is interrupted during live migration.**
OCP 4.21 Virtualization guide: *"Traffic passing through network interfaces to the default pod network is interrupted during live migration."*
This is a key motivator for using CUDN with Layer2 instead of the default pod network.
- **`FRRConfiguration` CRs are per-node on GCP, single shared CR on AWS.**
GCP controller creates one `FRRConfiguration` per selected router node, each targeting a single node via `nodeSelector`.
AWS reference creates one `FRRConfiguration` named `all-nodes` with `nodeSelector.matchLabels.bgp_router: "true"`.
- **OVN-K generates one FRRConfiguration per network and per node** from each RouteAdvertisements CR.
OCP 4.21 Advanced Networking guide: *"An FRRConfiguration object is generated for each network and node selected by a RouteAdvertisements CR with the appropriate advertised prefixes that apply to each node."*
- **Receive-side route filtering is not applied in OVN-K generated FRRConfigurations.**
OCP 4.21 Advanced Networking guide: *"Any filtering or selection of prefixes to receive are not considered in FRRConfiguration objects that are generated from the RouteAdvertisement CRs. Configure any prefixes to receive on other FRRConfiguration objects."*
This means the controller's FRRConfiguration CRs are the correct place for `toReceive.allowed.mode: all`.
- **CUDN pod IPs are in OVN annotations, not `status.podIPs`.**
`status.podIPs` in OVN-K stays on the infrastructure network for primary-UDN pods.
The CUDN address comes from `k8s.ovn.org/pod-networks` or `k8s.v1.cni.cncf.io/network-status`.
- **OVN-K generates its own `FRRConfiguration` CRs (`ovnk-generated-*`)** alongside any controller-managed or manually created CRs.
These are merged by MetalLB/FRR admission.
- **`ebgpMultiHop` on typed neighbors is rejected** by MetalLB admission when merged with `ovnk-generated-*` FRR CRs.
The workaround is `disable-connected-check` in `spec.raw` FRR config.
- **EgressIP advertisement from a Layer2 CUDN is not supported.**
OCP 4.21 Advanced Networking guide: *"Advertising EgressIPs from a user-defined network (CUDN) operating in layer 2 mode are not supported."*
- **Multiple External Gateways (MEG) are not supported with route advertisements.**
OCP 4.21 Advanced Networking guide: *"MEG is not supported with this feature."*
- **CUDN names should be 15 characters or fewer** for VRF device name matching in FRR.

### OpenShift Virtualization on GCP

- **OpenShift Virtualization on Google Cloud is GA** as of OCP 4.21.5 + OpenShift Virtualization 4.21.1.
OCP 4.21 Virtualization guide: *"OpenShift Virtualization on Google Cloud is generally available"* on bare-metal nodes.
Requires specific storage configuration and may need a project allow list for RWX multi-writer on bare metal.
- **VMs on primary UDN cannot use `virtctl ssh`, `oc port-forward`, or headless services.**
OCP 4.21 Virtualization guide documents these as explicit limitations.
- **Localnet CUDN: IPAM must be Disabled for VMs.**
OCP 4.21 Virtualization guide: *"`spec.network.localnet.ipam.mode`… The required value is `Disabled`. OpenShift Virtualization does not support configuring IPAM for virtual machines."*
- **VMs require RWX PVCs for live migration.**
OCP 4.21 Virtualization guide: *"Virtual machines (VMs) must have a persistent volume claim (PVC) with a shared ReadWriteMany (RWX) access mode to be live migrated."*
- **VM with >16 CPUs and `networkInterfaceMultiqueue: true` results in no connectivity.**
Known issue CNV-16107.
- **A dedicated migration network is recommended** to reduce impact on tenant traffic during live migration.
Configured via Multus NAD and `spec.liveMigrationConfig.network` on HyperConverged.

### GCP-Specific (NCC + Cloud Router)

- **Cloud Router uses exactly 2 interfaces (HA pair).**
GCP Router Appliance architecture requires primary + redundant interfaces.
Each router node peers with both interfaces = 2 BGP sessions per node.
- **NCC spoke, Cloud Router BGP peers, `canIpForward`, and `FRRConfiguration` CRs are operator-managed, not Terraform.**
Terraform manages only static infrastructure: NCC hub, Cloud Router, interfaces, firewalls.
This split avoids ownership conflicts on re-apply.
- **GCP workers use `/32` addresses on `br-ex`.**
FRR sees no path to the Cloud Router neighbor without `disable-connected-check` in the raw FRR config.
TCP to port 179 works, but BGP stays in `Active` state without this workaround.
- **Cloud Router interface IPs must not collide with other hosts on the worker subnet.**
Optional `router_interface_private_ips` or auto-allocated via `cidrhost` offset.
Reserved with `google_compute_address` (INTERNAL/GCE_ENDPOINT) by default.
- **`canIpForward` must be enabled on a GCE instance before it can be added to an NCC spoke as a router appliance.**
The API rejects spoke creation/update if any linked instance has `canIpForward=false`.
- **Cloud Router ASN must be in the RFC 6996 private range** (default `64512`); `frr_asn` defaults to `65003`.

### AWS-Specific (VPC Route Server)

- **VPC Route Server maintains routes from all BGP peers in RIB, but installs only one in FIB (subnet route tables) at a time.**
This means single-active routing with BGP keepalive-based failover, not ECMP for the CUDN prefix.
Documented in the AWS reference README.
- **Source/destination checking must be disabled on router instances.**
AWS equivalent of GCP `canIpForward`.
Done via a shell script targeting instances tagged `bgp_router=true`.
- **AWS Route Server supports up to 20 peers per interface.**
Stated in Slack discussion; constrains the "all nodes as peers" approach on AWS.
- **BFD with Route Server is not working** in the AWS reference.
Peers use `peer_liveness_detection = "bgp-keepalive"` with an inline comment noting BFD issues.
- **Route Server has 2 endpoints per private subnet, 6 total across 3 AZs.**
Each router node peers with the 2 endpoints in its own subnet.

### Cross-Cloud / Architecture

- **The operator selects every worker in the candidate pool** (default: nodes with `node-role.kubernetes.io/worker`, excluding infra).
Use the `BGPRoutingConfig` `spec.nodeSelector` fields to limit which machine pools participate in BGP.
- **AWS reference uses 3 dedicated bare-metal machine pools** (`c5.metal`, one per AZ, `replicas=1`), separate from the default compute pool.
These are the only BGP peers.
- **Test pods scheduled on non-router nodes cannot receive traffic from outside the cluster (VMs).**
This has been observed on GCP (e2e with test pods forced off router-labeled nodes — reproducible via manual **nodeAffinity** if needed).
The Slack thread from the AWS team confirms the same behavior: all nodes that host CUDN workloads need to be BGP peers.
- **Node lifecycle (termination, replacement, upgrade) on AWS showed zero packet loss** for CUDN VM traffic when ping ran at 1-second intervals.
Route Server adjusted subnet route tables to a surviving router node via BGP keepalive failover.
- **CUDN isolation is strict by default.**
Pods/VMs on different CUDNs cannot communicate (PASS in AWS test plan).
Worker host (`oc debug node`) to CUDN VM is also blocked (PASS).
Same-CUDN cross-node communication works (PASS).

### Operator / Reconciliation

- **The operator reconciles in this order:** labels, `canIpForward`, NCC spokes (numbered, ≤8 instances each), Cloud Router BGP peers, FRR CRs.
Event-driven (Node watch) + periodic drift loop (default 60s).
The operator uses CRD-based configuration (`BGPRoutingConfig` and `BGPRouter` under `routing.osd.redhat.com/v1alpha1`) instead of the legacy ConfigMap/env-var surface.
- **Cleanup uses a finalizer on `BGPRoutingConfig`** — deleting the CR triggers full teardown of peers, NCC spokes, FRR CRs, and router labels. `spec.suspended` provides temporary disable-with-cleanup (preserves config for re-enablement).
- **`clear_peers` via `RoutersClient.patch()` was a no-op** due to proto3 omitting empty repeated fields.
Fixed by using `RoutersClient.update()` (PUT) which replaces the full resource.
- The legacy Go and Python controllers (now archived under `archive/controller/`) implemented the same reconciliation logic; the operator carries it forward with the CRD-driven model.

---

## Assumptions and Hypotheses — Investigated

Each item scored by confidence percentage.
Items marked **RESOLVED** have been upgraded to verified or definitively answered.

### The Core Routing Problem

- **Hypothesis: the issue is outbound (egress) from CUDN pods on non-router nodes, not inbound. — 85%**
Reasoning: for inbound traffic, the VPC route points to a router node as next-hop; OVN should forward to the correct node via overlay.
For outbound, a non-router node has no FRR, no BGP sessions, and therefore no learned routes for VPC destinations.
A CUDN pod on that node has no path out.
This matches the Slack observation: "they seem to all need to be peers to get a VM a route out of the cluster to the VPC."
OVN-K Layer2 documentation confirms that Layer2 UDNs use a distributed logical switch spanning all nodes via Geneve overlay ([OVN-K OKEP-5193](https://ovn-kubernetes.io/okeps/okep-5193-user-defined-networks/)), which supports the claim that inbound forwarding through the overlay should work.
**Not conclusively tested** with packet captures or FRR route table inspection on a non-router node.
Remaining 15% uncertainty: both inbound and outbound could be broken; inbound OVN forwarding may have additional requirements for CUDN traffic that Layer2 overlay alone does not satisfy.
- **Hypothesis: OVN overlay does forward inbound CUDN traffic from a router node to a pod on a non-router node. — 75%**
OVN-K documentation confirms Layer2 topology connects all pods to the same distributed logical switch spanning all nodes.
The Layer2TransitRouter enhancement ([OKEP-5094](https://ovn-kubernetes.io/okeps/okep-5094-layer2-transit-router/)) specifically addresses gateway discovery and routing for Layer2 primary UDNs.
However, the router node must know to forward traffic into the OVN overlay rather than treating it as local-only.
The `canIpForward` flag enables IP forwarding at the GCE level, but the OVN datapath decision is a separate concern.
**Not tested** in isolation.
- **Hypothesis: making all worker nodes BGP peers resolves the problem. — 80%**
This is the recommendation from the AWS team (Slack thread) and the logical fix for the outbound problem.
The controller now peers **all** candidate workers by default.
**End-to-end validation** on GCP (VMs/pods on every worker) may still be pending.
Remaining uncertainty: there may be additional OVN-K or GCP-specific issues beyond BGP peering alone.

### GCP Cloud Router Limits — RESOLVED

- **RESOLVED: GCP Cloud Router supports 128 BGP peers per Cloud Router per VPC network and region. — 99%**
[GCP Cloud Router quotas and limits](https://cloud.google.com/network-connectivity/docs/router/quotas): *"Maximum number of BGP peers for each Cloud Router in a given VPC network and region: **128**"* (system limit, cannot be increased).
With 2 peers per worker (one per interface), this supports **up to 64 workers** on a single Cloud Router.
For typical cluster sizes (6-20 workers = 12-40 peers), this is well within the limit.
- **RESOLVED: NCC spoke is limited to 8 router appliance instances per spoke. — 99%**
[NCC quotas and limits](https://cloud.google.com/network-connectivity/docs/network-connectivity-center/quotas): *"Number of router appliance instances that can be linked to a spoke: **8**"* (system limit, cannot be increased).
**This is a critical constraint for the all-workers-as-peers design.**
For 6 workers (current default), this is fine.
For clusters larger than 8 workers, **multiple spokes are required** (one hub can have multiple spokes; spoke count per project per region is a quota, not a hard limit).
The controller creates **`{NCC_SPOKE_PREFIX}-0`**, **`{NCC_SPOKE_PREFIX}-1`**, … and deletes stale numbered spokes when the cluster shrinks.
- **BGP + route advertisements work on cloud VM workers despite "bare metal only" documentation. — 90%**
BGP routing and route advertisements are officially documented as supported only on bare-metal infrastructure.
Our OSD-GCP deployment uses cloud VM workers and BGP works in practice (FRR peers establish, routes are learned, e2e passes on router nodes).
The "bare metal only" language is a **support boundary**, not a technical blocker.
The AWS reference uses `c5.metal` instances (bare-metal on AWS), which is within the documented scope.
Remaining 10% uncertainty: undocumented edge cases may surface at scale or during upgrades, but not expected to be a fundamental blocker.
- **`canIpForward` on all workers has no known OSD policy blocking it. — 70%**
The openshift-installer creates GCP VMs with `canIpForward=false` by default ([openshift/installer#4884](https://github.com/openshift/installer/issues/4884)), but this is a default, not a managed-service enforcement.
The controller modifies `canIpForward` on every candidate worker via the GCE API and this works.
No OSD documentation explicitly prohibits modifying this property post-creation.
However, OSD manages worker node GCE instances as part of the platform.
If OSD's machine management (Machine API / MAPI) reconciles or replaces a worker, the replacement would have `canIpForward=false` by default, and the controller would need to re-enable it.
Remaining 30% uncertainty: OSD's MAPI could theoretically detect and revert `canIpForward` changes, or Red Hat platform policy could prohibit it in production.
There is no evidence of this, but it has not been formally validated with the OSD platform team.

### FRR / BGP Design

- **A single `FRRConfiguration` with broad `nodeSelector` would work on GCP. — 60%**
The AWS reference uses a single CR with `nodeSelector.matchLabels.bgp_router: "true"` and this works.
However, on GCP, the `spec.raw` section includes `disable-connected-check` which is required because of GCP's `/32` on `br-ex`.
A single CR with `spec.raw` applies the same raw config to all matching nodes, which is correct for this case (all nodes have the same Cloud Router neighbor IPs).
The risk is that MetalLB admission rejects the merged config when combined with OVN-K generated CRs.
Per-node CRs avoid this risk and provide granular lifecycle management.
**Not tested.** Keeping per-node CRs is the safer choice.
- **`disable-connected-check` in `spec.raw` works correctly when applied to many nodes simultaneously. — 90%**
The raw FRR config is per-router (ASN + neighbors), not per-node.
The same Cloud Router IPs apply to all nodes, so the raw config is identical.
FRR processes raw config independently per daemon instance.
Tested on 2-3 nodes; scaling to more nodes adds no new FRR-level complexity.
Remaining 10%: untested at scale, but no architectural reason for failure.
- **FRR on non-router nodes (from `ovnk-generated-*` CRs) does not conflict with adding Cloud Router neighbors. — 70%**
OVN-K creates `ovnk-generated-*` FRR CRs on all nodes (because `RouteAdvertisements` uses `nodeSelector: {}`).
These CRs handle route advertisement (CUDN prefix announcement).
The controller's CRs add Cloud Router as a neighbor (external BGP peering).
frr-k8s merges multiple CRs targeting the same node ([OKD docs](https://docs.okd.io/4.17/networking/ingress_load_balancing/metallb/metallb-frr-k8s.html)).
Known limitation: MetalLB rejects duplicate BGP peers with different node selectors ([metallb/metallb#1683](https://github.com/metallb/metallb/issues/1683)).
This should not apply here since the Cloud Router IPs are not in the OVN-K generated CRs.
However, `ebgpMultiHop` was already found to conflict with OVN-K CRs (documented in codebase); `disable-connected-check` in `spec.raw` is the workaround and is currently working.
Remaining 30%: there may be other merge conflicts when every node has both an OVN-K CR and a controller CR simultaneously, vs the current state where only 2-3 nodes have both.
- **iBGP / route reflector configuration is unnecessary if all nodes peer directly with Cloud Router. — 95%**
If every node has direct eBGP sessions to Cloud Router, each node independently learns routes from Cloud Router and advertises CUDN prefixes.
No iBGP redistribution needed — Cloud Router is the central route reflector-equivalent.
This is the standard Router Appliance architecture per GCP docs.
Remaining 5%: edge case where inter-node route awareness matters (e.g., multiple CUDNs with different prefixes and some nodes not hosting all CUDNs).

### GCP Route Selection — RESOLVED

- **RESOLVED: GCP Cloud Router uses ECMP when multiple router appliances advertise the same prefix with the same MED. — 99%**
[Router Appliance overview](https://cloud.google.com/network-connectivity/docs/network-connectivity-center/concepts/ra-overview): *"If multiple router appliance instances announce the same routing prefixes with the same MED, Google Cloud uses equal-cost multipath (ECMP) routing across all the router appliance instances."*
This is **different** from AWS Route Server's single-active FIB behavior.
**Implication**: with all workers advertising `10.100.0.0/16` and the same MED, GCP distributes inbound traffic across all workers via ECMP.
This is actually beneficial — traffic lands directly on the worker closest to the pod, reducing overlay hops.
It also means that if a worker goes down, ECMP removes it from the path (after BGP hold timer expires) rather than needing a full route table update.

### AWS Reference Applicability to GCP

- **AWS test results for CUDN isolation, service types, and node lifecycle are transferable to GCP. — 80%**
The CUDN/OVN-K layer is cloud-agnostic (same OpenShift version, same CUDN config).
CUDN isolation, ClusterIP services, and intra-CUDN connectivity are all OVN-K behaviors, not cloud-dependent.
Node lifecycle behavior (failover, scaling) differs: AWS uses Route Server single-active, GCP uses ECMP.
GCP ECMP should provide better failover characteristics (gradual redistribution vs full route switch).
Remaining 20%: service types (NodePort with `externalTrafficPolicy`) may behave differently due to ECMP vs single-active.
- **RESOLVED: AWS Route Server single-active FIB is NOT analogous to GCP Cloud Router — GCP uses ECMP. — 99%**
See GCP route selection resolution above.
AWS installs one next-hop in subnet route tables at a time; GCP distributes across all equal-cost next-hops.
This is a significant behavioral difference affecting HA, load distribution, and failover timing.
- **DaemonSet for `src/dst` check disable is analogous to GCP controller's `canIpForward` reconciliation. — 90%**
Both serve the same purpose: enable IP forwarding on router instances so they can forward CUDN traffic.
AWS: disabled via CLI script or DaemonSet (per-instance ENI operation).
GCP: enabled via GCE API (`InstancesClient.update()`) in the controller reconciliation loop.
Lifecycle difference: the GCP controller actively reconciles; the AWS DaemonSet is passive (runs on each new node).
Remaining 10%: GCP `canIpForward` is a VM-level property (all interfaces), while AWS src/dst check is per-ENI.

### Operational

- **Peering all workers does not create excessive BGP churn during cluster scaling or upgrades. — 75%**
BGP is designed for peer changes; Cloud Router handles 128 peers.
The controller debounces events (5s) and batches changes per reconciliation cycle.
Worker replacement (upgrade/scaling) triggers: NCC spoke update, Cloud Router peer add/remove, FRR CR create/delete.
Each GCP API call is asynchronous and typically completes in seconds.
Remaining 25%: at larger scales (20+ workers), concurrent node replacement during upgrades could cause multiple rapid spoke updates; spoke updates are serialized (one at a time).
The 8-instance spoke limit means multiple spokes at scale, adding complexity.
- **The 2-interface Cloud Router design is sufficient for all-worker peering. — 95%**
Cloud Router with 2 interfaces supports up to 128 BGP peers (system limit).
With 2 peers per worker, this supports 64 workers — well beyond typical OSD cluster sizes.
The HA pair ensures redundancy (if one interface fails, the other maintains sessions).
Remaining 5%: very large clusters (>64 workers) would exceed the 128-peer limit and require a second Cloud Router.

---

## Open Questions — Updated

Questions with investigation status and remaining uncertainty.

1. **RESOLVED: Does GCP Cloud Router support enough BGP peers for the target cluster size?**
**Yes.** 128 peers per Cloud Router (system limit).
2 peers per worker = **64 workers max per Cloud Router**.
Sufficient for all typical OSD cluster sizes.

2. **RESOLVED: NCC spoke is limited to 8 linked instances — how does this affect all-workers design?**
For clusters with **8 or fewer workers**: a single spoke (`{prefix}-0`) suffices.
For **more than 8 workers**: the controller shards workers across **multiple numbered spokes** on the same hub.
Hub can have multiple spokes; spoke count is a project quota (adjustable), not a hard limit.

3. **Does peering all candidate workers fix VM-to-pod connectivity on nodes that previously had no BGP session?**
**Implemented in code** (all candidates are peers); **full regression/QE on GCP** may still be pending.
Confidence based on design + AWS precedent: **85%**.

4. **Is the inbound path (VPC → worker → OVN overlay → pod on different node) actually working?**
OVN-K Layer2 documentation supports the claim that overlay forwarding should work.
With ECMP (now confirmed), inbound traffic may go directly to the pod's node, making this less critical.
Confidence inbound overlay forwarding works: **75%**.

5. **RESOLVED: What is GCP Cloud Router's route selection behavior?**
**ECMP** when multiple peers advertise the same prefix with the same MED.
Different from AWS Route Server's single-active FIB.
Beneficial: distributes load, faster failover.

6. **Should the GCP controller switch from per-node FRRConfiguration CRs to a single CR?**
Per-node CRs are safer (granular lifecycle, isolated from merge issues).
Single CR is simpler but has merge risk with OVN-K generated CRs.
**Recommendation**: keep per-node CRs. Confidence in recommendation: **85%**.

7. **Are there OSD platform policies that prevent `canIpForward` on all worker nodes?**
No evidence of OSD blocking `canIpForward` modifications.
The controller enables it on every candidate worker.
Confidence there is no blocker: **70%** (untested with OSD platform team).

8. **How does the Aviatrix peering limitation interact with all-nodes-as-peers?**
Not relevant to this repo (GCP, not AWS; no Aviatrix).
The customer moved to a simpler architecture.
**Deprioritized.**

9. **Does our non-VRF Layer2 CUDN topology require `routingViaHost=true`?**
The OCP 4.21 Advanced Networking guide describes a VRF-lite CUDN pattern that uses `routingViaHost: true` in the Network operator config.
Our deployment does **not** use VRF-based CUDNs — we use a simple Layer2 topology.
It is unclear whether `routingViaHost` is required for the OVN Layer2TransitRouter to correctly bridge CUDN egress traffic to the host routing table (and thus to FRR-learned routes).
If it is **not** needed, our current setup should work.
If it **is** needed, egress from CUDN pods may silently fail (or may work only by coincidence with the default routing path).
**Action required**: test egress from CUDN pods to VPC destinations with and without `routingViaHost`, or find definitive documentation for the non-VRF case.
Confidence that it is **not** needed for our case: **55%** (uncertain).

10. **Is OVN overlay forwarding reliable for CUDN inbound traffic arriving via ECMP at the "wrong" worker?**
With all workers as BGP peers and ECMP, `(N-1)/N` of flows arrive at a worker that does not host the target pod.
That worker must forward the packet through the OVN Layer2 overlay to the correct node.
Whether this cross-node forwarding path is reliably configured for externally-sourced traffic entering via the host network stack is not confirmed.
Confidence it works: **75%** (Layer2 broadcast domain should handle it, but untested for this exact ingress path).

---

## Sources

| Source | Type | Key contribution |
|--------|------|------------------|
| This repo (`osd-gcp-cudn-routing`) | Code + docs | GCP architecture, operator behavior, Phase 1-5 plan |
| AWS reference (`references/rosa-bgp`) | Code + docs | 3-node-per-AZ pattern, Route Server peering, test plan results |
| Internal Slack (BGP working group, March-April 2026) | Discussion | All-nodes-as-peers insight, Aviatrix limitations, FRR route reflector discussion |
| OVN-K admission validation (live cluster test) | Testing | `PodNetwork` + non-empty `nodeSelector` rejection |
| AWS reference test plan | QE testing | Connectivity, isolation, failover, node lifecycle results |
| [GCP Cloud Router quotas](https://cloud.google.com/network-connectivity/docs/router/quotas) | Vendor docs | 128 BGP peers per Cloud Router (system limit) |
| [GCP NCC quotas](https://cloud.google.com/network-connectivity/docs/network-connectivity-center/quotas) | Vendor docs | 8 router appliance instances per spoke (system limit) |
| [GCP Router Appliance overview](https://cloud.google.com/network-connectivity/docs/network-connectivity-center/concepts/ra-overview) | Vendor docs | ECMP with same-MED router appliances confirmed |
| [GCP Cloud Router learned routes](https://cloud.google.com/network-connectivity/docs/router/concepts/learned-routes) | Vendor docs | Best path selection, MED-based route processing |
| [OVN-K UDN design (OKEP-5193)](https://ovn-kubernetes.io/okeps/okep-5193-user-defined-networks/) | Upstream docs | Layer2 distributed logical switch, cross-node overlay |
| [OVN-K Layer2TransitRouter (OKEP-5094)](https://ovn-kubernetes.io/okeps/okep-5094-layer2-transit-router/) | Upstream docs | Gateway routing for Layer2 primary UDNs |
| [frr-k8s / MetalLB FRR CR merging](https://docs.okd.io/4.17/networking/ingress_load_balancing/metallb/metallb-frr-k8s.html) | Upstream docs | Multiple FRRConfiguration CR merge behavior |
| [openshift/installer#4884](https://github.com/openshift/installer/issues/4884) | GitHub issue | `canIpForward` default disabled on GCP, no installer config |
| OCP 4.21 Advanced Networking guide (PDF, 2026-03-30) | Red Hat docs | RouteAdvertisements constraints, FRR-K8s behavior, BGP bare-metal-only statement, EgressIP limitations |
| OCP 4.21 Virtualization guide (PDF, 2026-03-30) | Red Hat docs | Layer2 UDN for VMs, persistent IPAM for live migration, GCP GA, masquerade interruption during migration |
