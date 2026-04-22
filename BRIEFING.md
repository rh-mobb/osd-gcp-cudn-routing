# CUDN BGP Internet Egress — Issues

> **Status:** Verified in production · OCP 4.21 · April 2026
> **Scope:** OSD/GCP (hub/spoke BGP) confirmed and ROSA/AWS (ROSA-BGP) suspected

---

## Executive Summary

CUDN pods and VMs on OpenShift Dedicated **cannot reliably reach the internet**
in any architecture investigated: GCP hub/spoke, single-VPC ILB, or (with high
confidence) ROSA-BGP on AWS.

The failure is not a configuration gap or a missing firewall rule.
It is a **fundamental mismatch** between how OVN-Kubernetes tracks connections
and how cloud ECMP routing delivers return packets.
All intra-cluster and VPC/on-prem connectivity is unaffected.

---

## What Works and What Doesn't


| Traffic path                        | Reliable? | Why                                          |
| ----------------------------------- | --------- | -------------------------------------------- |
| CUDN pod → CUDN pod (intra-cluster) | Yes       | OVN Geneve overlay, no NAT involved          |
| VPC host → CUDN pod (inbound)       | Yes       | RFC-1918 source; OVN accepts on any worker   |
| CUDN pod → VPC host (egress)        | Yes       | RFC-1918 return source; same reason          |
| CUDN pod → on-prem / peered VPC     | Yes       | RFC-1918 return source; same reason          |
| CUDN pod → internet                 | **No**    | Public IP return source; drops on wrong node |
| KubeVirt masquerade VM → internet   | **No**    | Masquerades to CUDN IP (not worker VPC IP); same failure |


**The key distinction:** OVN-K allows new connections from RFC-1918 source IPs
on any worker and Geneve-forwards to the correct pod.
Internet return traffic carries a **public source IP** (e.g. `src=8.8.8.8`),
which OVN-K only accepts on the node that originated the connection.

---

## Root Cause: The Five-Step Failure Chain

Every architecture investigated fails at step 5.
The failure is inside OVN-K, not in the routing topology.

**Step 1 — VM initiates egress.**
A KubeVirt VM running on Worker B has a persistent CUDN IP (`10.100.0.9`).
Its traffic leaves via the virt-launcher pod's OVN secondary interface (`ovn-udn1`).
OVN-K does **not** SNAT the packet — `src=10.100.0.9` exits the worker NIC as-is,
regardless of whether the VM uses `bridge` or `masquerade` binding
(masquerade SNATs to the virt-launcher pod's own CUDN IP, not the worker's VPC IP).

**Step 2 — Hub NAT VM masquerades.**
The packet traverses VPC peering to the hub, where a NAT VM rewrites
`src=10.100.0.9` to its own external IP (e.g. `34.x.x.x`).
The internet sees the NAT VM's IP — the VM's CUDN IP is hidden.

**Step 3 — Return packet is DNAT'd back to the CUDN IP.**
The internet replies to `34.x.x.x`.
The hub NAT VM's conntrack entry rewrites the return: `src=8.8.8.8, dst=10.100.0.9`.
This packet re-enters the spoke VPC via peering.

**Step 4 — Cloud Router ECMP routes to a random worker.**
The spoke VPC routing table has 10 equal-cost paths for `10.100.0.0/16`
(5 BGP-enabled workers × 2 Cloud Router peers).
The return packet's 5-tuple hash selects one path — potentially any of the 10,
not necessarily Worker B where the VM lives.

**Step 5 — OVN-K drops on the wrong worker.**
OVN-K's conntrack state for this flow exists **only on Worker B**.
When the return lands on Worker A, OVN-K sees `src=8.8.8.8` (a public internet IP)
with no `ct.est` entry and drops the packet silently.
Only the ~2 of 10 ECMP paths that happen to land on Worker B succeed —
producing the intermittent connectivity observed in testing.

---

## GCP-Specific Constraint

GCP Cloud NAT **silently drops CUDN traffic** (`src=10.100.0.x`) because the
source IP is not registered against the worker's NIC in the GCP network stack.
This means Cloud NAT is not a viable option for CUDN internet egress on GCP,
regardless of routing topology.

The hub/spoke architecture works around this by running Linux `MASQUERADE` on
the NAT VMs **before** GCP sees the packet, so GCP only ever sees the NAT VM's
registered NIC IP.
This workaround solves the GCP constraint but introduces the ECMP/conntrack
problem described above.

---

## Architecture Comparison


| Architecture                   | Internet NAT                   | ECMP exposure            | Success rate               | Tested? | Verdict      |
| ------------------------------ | ------------------------------ | ------------------------ | -------------------------- | ------- | ------------ |
| GCP Hub/Spoke (current)        | Hub NAT VMs (Linux MASQUERADE) | 10 paths (5 workers × 2) | ~10–20%                    | Yes     | Fails        |
| GCP Single-VPC + Cloud NAT     | Cloud NAT (GCP managed)        | Same Cloud Router ECMP   | 0% (Cloud NAT drops CUDN)  | No      | Fails        |
| GCP Single-VPC + ILB + NAT VMs | NAT VMs (Linux MASQUERADE)     | ILB ECMP (same problem)  | Untested; expected to fail | No      | Likely fails |
| AWS ROSA-BGP (Route Server)    | AWS NAT Gateway (no NIC check) | Active/standby (1 of N)  | Untested; expected to fail | No      | Likely fails |


---

## Why ROSA-BGP on AWS is Likely Broken Too

AWS NAT Gateway does not have GCP's NIC-registration restriction, so the
Cloud NAT obstacle does not exist on AWS.

However, the return-path problem is identical.
The VPC Route Server installs routes to `10.100.0.0/16` pointing at worker
nodes.
Even in an active/standby configuration where only one worker is the active
next-hop, the NAT Gateway's DNAT'd return (`src=8.8.8.8, dst=10.100.0.x`)
goes to that one specific worker.

Any pod or VM **not** running on that exact worker fails with the same reason:
no `ct.est` on the receiving node.
Effective success rate: 1 in N, where N is the number of workers.

This has **not been tested** in the ROSA-BGP reference test plan, which covered
inbound connectivity, isolation, and node lifecycle — not pod-initiated internet
egress.

---

## Workarounds Investigated and Ruled Out


| Approach                               | Outcome                      | Root cause                                                                                                                           |
| -------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `routingViaHost: true` + host nftables | Broke CUDN routing entirely  | CUDN uses `ovn-udn1` (OVN pipeline); host nftables is never invoked. Setting also reconfigures OVN gateway routers for all networks. |
| EgressIP (OVN-K)                       | Not available for Layer2 UDN | Documented unsupported in OCP 4.21. Broken on `/32`-per-node platforms (OCPBUGS-48301).                                              |
| AdminPolicyBasedExternalRoute          | Not applicable               | Applies to primary pod network only; CUDN secondary interface is unaffected.                                                         |
| Dual-SNAT on NAT VM                    | Breaks TCP                   | Rewriting `src=8.8.8.8 → 10.20.0.3` on the return causes the pod to RST (unexpected source for its connection).                      |


---

## Future Fix Path

**OKEP-5094 (Layer2TransitRouter)** introduces EgressIP support for Layer2
primary UDN via a transit router topology.

- Upstream PRs merged: September–November 2025
- Target release: OCP 4.22 (not GA as of April 2026)
- Availability on OSD/ROSA: not confirmed

This would allow assigning an EgressIP to a CUDN namespace, pinning egress to
a designated node that holds stable conntrack state — eliminating the ECMP/
conntrack mismatch at source.

---

## Recommendations

1. **Do not position CUDN as an internet egress path** for pods or VMs in OCP 4.21 on any cloud.
2. **KubeVirt `masquerade` binding does not solve internet egress** for VMs on a primary CUDN.
   KubeVirt masquerade SNATs to the virt-launcher pod's primary network IP, which on a primary UDN is the CUDN IP (`10.100.0.x`) — not the worker's VPC IP.
   OVN-K sees the same CUDN-sourced traffic as with `bridge` binding, and the ECMP/conntrack failure applies equally.
   Early observations that masquerade VMs appeared to work were coincidental ECMP hits, not a structural difference.
3. **Reserve CUDN for intra-cluster and VPC/on-prem connectivity** where stable pod IPs are the requirement.
4. **Treat ROSA-BGP internet egress as untested and likely broken** by the same mechanism; validate before customer use.
5. **Track OKEP-5094 / OCP 4.22 GA** as the earliest viable fix; confirm OSD/ROSA delivery timeline with the networking team.

---

## Evidence Base

- Production testing on OSD/GCP (April 2026): `mtr`, `ping`, `curl`, `/proc/net/nf_conntrack`, OVN-K flow analysis
- Archive review: GCP ILB PoC (`archive/cluster_ilb_routing/`) and NAT gateway plan (`archive/docs/nat-gateway.md`)
- AWS ROSA-BGP reference architecture comparison (`archive/ILB-vs-BGP.md`)
- OCP 4.21 Advanced Networking guide (BGP, RouteAdvertisements, EgressIP limitations)
- [OKEP-5094](https://github.com/ovn-org/ovn-kubernetes/issues/5094) upstream tracking
- Full findings: `[KNOWLEDGE.md](KNOWLEDGE.md)` — "CUDN internet egress is fundamentally ECMP-unreliable"

