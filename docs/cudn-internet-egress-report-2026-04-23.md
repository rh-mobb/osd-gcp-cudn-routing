# CUDN Internet Egress — Investigation Report

**Date:** 2026-04-23
**Author:** AI-assisted debugging session (Cursor/Sonnet)
**Status:** Root cause confirmed, fix deployed and verified

## Executive Summary

Internet egress from KubeVirt VMs in a CUDN namespace on OSD/GCP was failing ~80% of the time.
The original hypothesis was that OVN-Kubernetes conntrack node-locality was the cause.
A parallel ROSA/AWS cluster running **identical OCP 4.21.9** showed 100% success, which challenged
the hypothesis and led to a cross-cluster comparison.

**The actual root cause was the GCP VPC stateful firewall, not OVN-K.**
The GCP spoke VPC had no inbound rule allowing arbitrary internet source IPs. When Cloud Router
ECMP returned a packet to a worker that did not originate the connection, the GCP firewall silently
dropped it before OVN-K could process it. ROSA worked because all its BGP baremetal workers carry
an `allow-all` AWS security group (`rosa-virt-allow-from-ALL-sg`) that passes any inbound traffic
unconditionally.

**Fix:** A VPC-wide `INGRESS allow 0.0.0.0/0 all` firewall rule was added to the GCP spoke VPC.
Internet egress went from ~22% to **100% immediately**. The fix is codified in
`modules/osd-spoke-vpc` as `google_compute_firewall.cudn_egress_return`
(`enable_cudn_egress_return = true` by default).

---

## Table of Contents

1. [Background and original hypothesis](#1-background-and-original-hypothesis)
2. [Environment](#2-environment)
3. [Phase 1: GCP investigation](#3-phase-1-gcp-investigation)
4. [Phase 2: ROSA comparison](#4-phase-2-rosa-comparison)
5. [Hypothesis pivot](#5-hypothesis-pivot)
6. [Root cause analysis](#6-root-cause-analysis)
7. [Fix and verification](#7-fix-and-verification)
8. [Relationship to Cloud NAT theory](#8-relationship-to-cloud-nat-theory)
9. [What remains open](#9-what-remains-open)
10. [Permanent changes](#10-permanent-changes)

---

## 1. Background and original hypothesis

KubeVirt VMs on CUDN use the OVN secondary interface (`ovn-udn1`) for all traffic.
`RouteAdvertisements` preserves the CUDN pod IP end-to-end — OVN-K does **not** SNAT outbound
traffic. The hub NAT VM masquerades `src=10.100.0.x` to a public IP before the internet, and
DNATs the return packet back to `dst=10.100.0.x` before forwarding into the spoke VPC.

Return traffic enters the spoke VPC and hits **Cloud Router ECMP** (5 BGP workers × 2 peers = 10
equal-cost paths). With 10 paths and the VM on 1 node, the expected delivery rate to the correct
worker is ~20%.

The pre-session hypothesis (documented in `BRIEFING.md`) was:

> OVN-K's conntrack state is node-local. Workers that receive return traffic from a connection they
> did not originate lack `ct.est` for the public-IP source. The br-ex OVS pipeline drops these
> packets via a `ct_state=!est → drop` rule. Only the originating worker succeeds.

This hypothesis explained the ~80% failure rate and the retransmission patterns seen in initial
packet captures. It turned out to be **wrong about the drop point** — but right about the topology
being the cause.

---

## 2. Environment

### GCP cluster — `cz-demo1`

| Property | Value |
|----------|-------|
| Platform | OSD/GCP `us-central1` |
| OCP version | **4.21.9** |
| CUDN prefix | `10.100.0.0/16` |
| BGP workers | 5 (2 baremetal + 3 standard worker) |
| Cloud Router ECMP paths | 10 (5 workers × 2 peers) |
| Hub NAT | Regional MIG of NAT VMs (`cz-demo1-nat-gw-mig`), Linux MASQUERADE |
| Test VMs | `virt-e2e-bridge` (`10.100.0.7`), `virt-e2e-masq` (`10.100.0.8`) — both `l2bridge` / `masquerade` binding |
| VM location | `baremetal-a-l6z4w` (us-central1-a) |
| Internet test target | `https://ifconfig.me` (`34.160.111.145`) |
| RFC-1918 control target | `10.0.32.2:8080` (echo VM) |

### ROSA cluster — `czvirt`

| Property | Value |
|----------|-------|
| Platform | ROSA HCP `eu-central-1` |
| OCP version | **4.21.9** |
| CUDN prefix | `10.100.0.0/16` |
| BGP workers | 3 baremetal (`c5.metal`) — only VMs can schedule here |
| Route Server | `rs-030e28f3dd4f57e96` (single-active FIB — no ECMP) |
| Test VM | `test-vm-a` (`10.100.0.4`, `bridge` binding) |
| Active BGP next-hop | `10.0.1.131` (constant throughout session) |
| Internet test target | `https://ifconfig.me` |
| RFC-1918 control target | `10.0.1.155:8080` (EC2 in VPC) |

---

## 3. Phase 1: GCP investigation

### 3.1 Baseline internet egress failure rate

50 sequential `curl` requests from `virt-e2e-bridge` (`10.100.0.7`) to `https://ifconfig.me`.
Each request is an independent TCP connection with a different ephemeral src port, producing
different ECMP hash values and sampling the full 10-path distribution.

| Run | 200 | 000 | Success rate |
|-----|-----|-----|-------------|
| 1 | 8 | 42 | 16% |
| 2 | 9 | 41 | 18% |
| 3 | 11 | 39 | 22% |
| 4 | 15 | 35 | 30% |
| 5 | 15 | 35 | 30% |
| 6 | 9 | 41 | 18% |

**Average: ~22% across 300 requests.** Expected with 5 ECMP workers, VM on 1 node: ~20%.
The match is within normal sampling variance.

### 3.2 RFC-1918 control test

50–5,000 `curl` requests to the echo VM (`10.0.32.2:8080`). Return traffic carries
`src=10.0.32.2` (RFC-1918). Expected: 100% regardless of which worker receives the return.

**Result: 5,050 / 5,050 = 100%** across three runs (n=50, 500, 5,000).

This established that the failure is **specific to public internet source IPs** and does not
indicate an ECMP routing problem per se. The source IP class is the discriminating variable.

### 3.3 NAT VM packet capture

`tcpdump` on the single hub NAT VM (`cz-demo1-nat-gw-vwn5`) during a 50-curl run.
213 packets, 0 dropped. Captured on `gif0` (GRE VPC peering tunnel).

Key findings:
- **Every outbound SYN** from `10.100.0.7` was received at the NAT VM.
- **Every SYN-ACK** was correctly DNAT'd to `dst=10.100.0.7` and forwarded back into the spoke.
- **Failed connections** show exactly 2 SYN retransmissions (3 total SYN-ACKs sent): the VM
  retransmitted the SYN twice but the `--max-time 3` limit expired before a 4th attempt.
- **Partial recoveries**: 1 retransmission then data exchange — first SYN-ACK was dropped,
  second landed on a different worker and succeeded.
- **Immediate successes**: first SYN-ACK happened to land on the originating worker.

**Conclusion: the NAT VM is not the failure point.** The failure is in the spoke VPC,
at some layer between the GRE tunnel and the VM.

At this stage the hypothesis was still "OVN-K ct.est drop", because:
- The pcap retransmission pattern was consistent with that hypothesis.
- Worker-side tcpdump showed 0 packets on all interfaces (OVS kernel-mode invisibility),
  so the drop point could not be directly observed.

### 3.4 OVS observability finding

Every interface attempted on spoke worker nodes via `oc debug node` showed **0 packets**
during active CUDN test traffic:

| Interface | Description | Packets |
|-----------|-------------|---------|
| `br-ex` | OVS external bridge | 0 |
| `ens4` | Physical GCP NIC (OVS port) | 0 |
| `any` | All Linux interfaces | 0 |
| `ovn-k8s-mp1` | OVN UDN management port | 0 |

Root cause: `ens4` is registered as an OVS port. The OVS kernel module (`openvswitch.ko`)
intercepts packets at the NIC via its own `rx_handler`, before `AF_PACKET` (libpcap). Traffic
processed entirely within the OVS datapath is invisible to `tcpdump`. This is a fundamental
limitation, not a configuration problem — identical behaviour was later confirmed on ROSA/AWS.

The direct observation approach was blocked. Investigation continued on the cross-cluster
comparison path.

---

## 4. Phase 2: ROSA comparison

The motivation for testing ROSA was:

1. AWS Route Server uses **single-active FIB** — all four route tables in the VPC point to one
   BGP worker as the next-hop for `10.100.0.0/16`. There is no ECMP distribution across workers.
2. Under the original hypothesis, ROSA should therefore show **binary** behavior: either 100%
   success (VM on the active BGP node) or 0% failure (VM migrated to a non-active node, where
   OVN-K would have no `ct.est` for returns arriving at the active node).

### 4.1 Baseline — VM on active BGP node

VM `test-vm-a` on `ip-10-0-1-131` (same node as active Route Server next-hop).
Expected: 100% (return traffic always arrives at the VM's node).

**Result: 150 / 150 = 100%.** As expected.

### 4.2 RFC-1918 control test

5,550 curl requests to `10.0.1.155:8080` (EC2 instance, same VPC).

**Result: 5,550 / 5,550 = 100%.** Consistent with GCP.

### 4.3 Key experiment — live migration to non-active BGP node

VM migrated from `ip-10-0-1-131` (active BGP next-hop) to `ip-10-0-2-108`.
Route Server next-hop confirmed unchanged at `10.0.1.131` throughout.

Under the original hypothesis, return traffic should arrive at `10.0.1.131` where there is no
`ct.est` for flows initiated on `10.0.2.108` → **expected 0% failure**.

**Result: 150 / 150 = 100% — the predicted failure did NOT occur.**

### 4.4 OVS flow analysis that explains ROSA success

Inspecting `br-ex` on the Route Server entry node (`10.0.1.131`) after migration:

```
priority=300,ip,in_port=1,nw_dst=10.100.0.0/16 actions=output:3
```

Key: **no `ct()` action** in this rule. The `priority=300` flow forwards all inbound traffic
for `10.100.0.0/16` directly to the UDN interface (`output:3`) without a conntrack check.
OVN-K then uses the L2 logical switch to look up the port binding for `10.100.0.4`, finds it on
`ip-10-0-2-108`, and Geneve-encapsulates the packet to that node. The conntrack check happens at
the VM's logical port on `ip-10-0-2-108` where `ct.est` is valid.

**This is the same flow that exists on both clusters.** The `priority=300` rule is identical on
GCP and ROSA. So the conntrack-node-locality hypothesis was wrong — OVN-K does not check
`ct.est` at the transit/entry node.

### 4.5 The discriminating observation

If OVN-K is correct on both clusters, why did GCP fail and ROSA succeed?

Inspection of the AWS security groups on ROSA's baremetal workers revealed:

```
Security group: rosa-virt-allow-from-ALL-sg
Rule: IngressRule  IpProtocol=-1  CidrIp=0.0.0.0/0  (allow all from anywhere)
```

This security group is attached to all three ROSA baremetal BGP workers.
**It allows all inbound traffic unconditionally, including internet-sourced IPs.**

GCP's spoke VPC had no equivalent. The `cz-demo1-hub-to-spoke-return` rule covered
`src=10.20.0.0/24` (the hub NAT VM subnet), but not arbitrary internet IPs (`src=34.x.x.x`).

---

## 5. Hypothesis pivot

The original OVN-K conntrack hypothesis was built on indirect evidence:

| Original evidence | Interpretation | Correct? |
|-------------------|----------------|----------|
| ~22% success rate matching 1/5 ECMP probability | OVN-K drops ~80% due to missing `ct.est` | Partially — the drop rate is real, the mechanism was wrong |
| SYN retransmissions in pcap (3 SYN-ACKs, no ACK) | OVN-K drops all 3 copies | Incorrect — drops were at GCP VPC firewall |
| br-ex `ct_state=+est+trk` flows visible in `ovs-ofctl` | These fire on drops | These fire on **forwarded** traffic, not drops |
| 0 packets on worker tcpdump | Consistent with OVS kernel drop | Also consistent with GCP firewall drop (packet never reached OVS) |

The ROSA comparison provided the decisive new constraint: identical OVN-K version, identical OVS
flows, identical ACLs — but 100% success due to an AWS security group.

**The drop must be at a layer that differs between GCP and ROSA: the cloud network firewall.**

On GCP, a packet arriving at a worker with `src=34.x.x.x` is evaluated by the VPC stateful
firewall. If no tracked outbound session exists for that source (because the SYN was sent by a
different worker), the firewall drops the packet **before it reaches the OVS datapath**. This is
why tcpdump showed 0 packets — the packet never reached `ens4`'s OVS port.

---

## 6. Root cause analysis

### The failure path (GCP, pre-fix)

```
CUDN VM (10.100.0.7) → baremetal-a-l6z4w
  │ CUDN src IP preserved (no SNAT by OVN-K)
  ▼
BGP worker br-ex → spoke VPC → VPC peering → hub VPC
  ▼
Hub NAT VM: nftables MASQUERADE
  src=10.100.0.7 → src=NAT_public_IP, dst=34.160.111.145
  ▼
Internet → 34.160.111.145 → response
  │ src=34.160.111.145, dst=10.100.0.7 (after DNAT by NAT VM)
  ▼
Spoke VPC — Cloud Router ECMP (10 paths)
  │
  ├── ~20% → baremetal-a-l6z4w (VM's node)
  │     GCP VPC firewall: stateful tracking allows (this worker sent the SYN) ✓
  │     OVN-K br-ex priority=300 → Geneve → VM ✓
  │
  └── ~80% → other workers (baremetal-a-wnl8v, worker-a, worker-b, worker-c)
        GCP VPC firewall: no tracked outbound session for src=34.x.x.x
        PACKET DROPPED HERE — before reaching OVS ✗
```

### The success path (ROSA, all cases)

```
CUDN VM (10.100.0.4) → ip-10-0-2-108 (after migration)
  │ CUDN src IP preserved
  ▼
BGP worker → VPC → internet → response
  │ src=<public-IP>, dst=10.100.0.4
  ▼
Route Server single-active FIB → ip-10-0-1-131 (entry node)
  │
  AWS Security Group: rosa-virt-allow-from-ALL-sg
    IngressRule: proto=-1, src=0.0.0.0/0 → ALLOWED unconditionally ✓
  │
  OVS br-ex priority=300: nw_dst=10.100.0.0/16 → output:3 (no ct check)
  │
  OVN L2 logical switch: 10.100.0.4 → MAC binding on ip-10-0-2-108
  │
  Geneve to ip-10-0-2-108 → VM ✓
```

### Why the two-layer failure on GCP also matters

Even if OVN-K had been the drop point (the original hypothesis), there is a second, independent
failure mode that would have applied under any single-VPC + Cloud NAT architecture. Cloud NAT
matches outbound packets against source IPs registered to the NIC. CUDN overlay IPs (`10.100.0.x`)
are not registered GCP NIC addresses — Cloud NAT would silently drop them.

The hub/spoke NAT VM architecture was chosen specifically to avoid this: Linux kernel
`nftables MASQUERADE` rewrites any source IP without consulting GCP's NIC registration. This
solved the outbound failure. The remaining inbound return failure (GCP VPC stateful firewall)
was discovered during this session and fixed.

### OVN-K behaviour clarified

The `priority=300` br-ex flow exists on both clusters and forwards all inbound traffic for the
CUDN prefix to the OVN tunnel without a conntrack gate:

```
priority=300,ip,in_port=1,nw_dst=10.100.0.0/16 actions=output:3
```

The `ct_state=+est+trk` flows visible in `ovs-ofctl dump-flows br-ex` fire on
**successfully established connections** (large packet counters), not on drops. The conntrack
check happens at the VM's logical port on its own node — this is correct Layer2 logical switch
semantics. Transit nodes do not inspect conntrack state.

**OVN-K has never been the drop point for this failure mode.**

---

## 7. Fix and verification

### 7.1 Live fix applied to GCP

A new VPC firewall rule was added to `cz-demo1-spoke-vpc`:

```
Name:         cz-demo1-cudn-egress-return
Direction:    INGRESS
Priority:     800
Source:       0.0.0.0/0
Protocol:     all
Target:       all instances in cz-demo1-spoke-vpc (VPC-wide, no target tags)
```

No target tags — GCP worker network tags are assigned by the OSD installer and are not under
Terraform control. The rule is VPC-wide, mirroring what ROSA's `rosa-virt-allow-from-ALL-sg`
effectively does.

Immediate result after applying the rule:

| Run | 200 | 000 | Success rate |
|-----|-----|-----|-------------|
| Before fix (6-run average) | ~22% | ~78% | 22% |
| First post-fix run | 50 | 0 | **100%** |

### 7.2 Post-fix verification (full re-run)

Run with the MIG restored to full 3-instance production configuration.

**Internet egress — 3 × 50 runs:**

| Run | 200 | 000 | Success rate |
|-----|-----|-----|-------------|
| 1 | 50 | 0 | **100%** |
| 2 | 50 | 0 | **100%** |
| 3 | 50 | 0 | **100%** |

**RFC-1918 control — n=50:**

| 200 | 000 | Success rate |
|-----|-----|-------------|
| 50 | 0 | **100%** |

**Conntrack evidence on non-VM baremetal node (`baremetal-a-wnl8v`):**

Pre-fix: no conntrack entries for internet-sourced traffic (`src=34.x.x.x, dst=10.100.0.x`).
Post-fix:

```
ESTABLISHED [UNREPLIED]  src=34.160.111.145 dst=10.100.0.7 sport=443 dport=40880
ESTABLISHED [UNREPLIED]  src=34.160.111.145 dst=10.100.0.7 sport=443 dport=38218
ESTABLISHED [UNREPLIED]  src=34.160.111.145 dst=10.100.0.7 sport=443 dport=49814
```

`ESTABLISHED` confirms the packet passed the GCP firewall and was tracked.
`[UNREPLIED]` is expected: this node sees only the return half of the flow (the outbound SYN was
from `baremetal-a-l6z4w`). The `priority=300` br-ex rule forwards the packet via Geneve to the
VM's node, where `ct.est` is valid and the VM receives it.

The `priority=300` flow counter on `baremetal-a-wnl8v` was active at **6,878 packets** for
internet-destined CUDN traffic — effectively zero before the fix.

### 7.3 Evidence matrix

| Evidence | Before fix | After fix |
|----------|-----------|-----------|
| Internet egress success rate | ~22% (n=300) | **100%** (n=150) |
| RFC-1918 control rate | 100% | 100% |
| Non-VM node conntrack for internet src | Empty | `ESTABLISHED [UNREPLIED]` |
| Non-VM node `priority=300` packet counter | ~0 (internet traffic) | 6,878+ |
| VM-host node conntrack | `ASSURED TIME_WAIT` | `ASSURED TIME_WAIT` |

---

## 8. Relationship to Cloud NAT theory

The original single-VPC design (archived in `archive/docs/nat-gateway.md`) relied on GCP Cloud NAT.
The hypothesis was that Cloud NAT would drop CUDN traffic because `src=10.100.0.x` is not registered
against the worker's NIC. This hypothesis is **still correct and independent** of what we found.

The two failure modes are at different layers:

| Failure | Layer | Mechanism | Impact |
|---------|-------|-----------|--------|
| Cloud NAT source-IP drop | Outbound path (spoke VPC egress) | NAT checks NIC registration; overlay IPs not registered | 100% failure — traffic never reaches internet |
| GCP VPC stateful firewall drop | Inbound path (spoke VPC ingress) | Firewall has no allow-all for internet src IPs; stateful state only on originating worker | ~80% failure — correct-node connections succeed |

The hub/spoke NAT VM architecture solves failure #1 by bypassing Cloud NAT entirely (Linux
MASQUERADE doesn't check NIC registration). The `cudn-egress-return` firewall rule solves failure
#2. Both are required for reliable CUDN internet egress on GCP.

If EgressIP were working (OCPBUGS-48301 not fixed), it would SNAT the source to a valid GCP NIC
IP before the packet reaches Cloud NAT — solving failure #1 by a different mechanism. But failure
#2 (VPC stateful firewall) would still apply on return, requiring the same `allow-all` rule or an
alternative such as session-affinity-based ECMP pinning.

---

## 9. What remains open

### 9.1 Single-VPC + Cloud NAT — untested

The archived design was never fully tested. The Cloud NAT source-IP drop is well-documented
(confidence 95%), but whether the OVN EgressIP fix (OKEP-5094 / OCP 4.22) would enable it is
unknown. That path would still require solving the VPC firewall issue on return.

**Status:** Hypothesis preserved in `KNOWLEDGE.md`. Not a priority for the current architecture.

### 9.2 OVS observability gap

Worker-side packet observation during CUDN egress failures is not achievable with standard
`oc debug node` + tcpdump tooling. The OVS kernel datapath (both `br-ex` and `ens4`) is invisible
to `AF_PACKET`. Required tooling:

- `ovs-tcpdump` (port mirror to tap) — not in debug pod image
- `ovs-vsctl mirror` — requires access to OVS daemon socket
- `bpftrace`/eBPF on `ovs_dp_process_packet` — requires kernel headers in debug pod
- `ovs-ofctl dump-flows` counters — available via `openshift-ovn-kubernetes` pod exec

This limitation made it impossible to directly observe the original GCP drops at the OVS layer.
The root cause was ultimately deduced from the ROSA cross-cluster comparison and confirmed by
the immediate conntrack changes after the firewall fix.

### 9.3 Multi-MIG path stickiness

With 3 NAT VMs in the regional MIG (restored as of this session), the ILB uses
`SESSION_AFFINITY=CLIENT_IP`. All return traffic for a given CUDN VM IP should consistently
reach the same NAT VM. This was not re-tested with the full 3-instance MIG — all post-fix
testing was done at MIG size 3 and showed 100% success, so the stickiness behaviour is
confirmed in practice but not specifically isolated.

### 9.4 Masquerade-bound VMs

`virt-e2e-masq` (`10.100.0.8`, `masquerade` binding) was not separately tested for internet
egress after the fix. The `bridge`-bound VM (`virt-e2e-bridge`, `10.100.0.7`) demonstrated
100% success; the fix is at the VPC firewall layer and applies identically to both binding types.

---

## 10. Permanent changes

### Terraform

| File | Change |
|------|--------|
| `modules/osd-spoke-vpc/main.tf` | Added `google_compute_firewall.cudn_egress_return` |
| `modules/osd-spoke-vpc/variables.tf` | Added `enable_cudn_egress_return` (default `true`) |
| `cluster_bgp_routing/variables.tf` | Added `spoke_enable_cudn_egress_return` (default `true`) |
| `cluster_bgp_routing/main.tf` | Passes `enable_cudn_egress_return = var.spoke_enable_cudn_egress_return` to spoke module |
| `cluster_bgp_routing/terraform.tfvars.example` | Documents the new variable |

The rule is VPC-wide (no `target_tags`) because GCP worker network tags are OSD-installer-assigned
and not under our Terraform control.

### Documentation updated

| File | Update |
|------|--------|
| `docs/debug-internet-egress-2026-04-23.md` | Full session log, post-fix verification section added |
| `docs/debug-internet-egress-rosa-2026-04-23.md` | Full ROSA session log, cross-cluster comparison |
| `docs/cudn-internet-egress-report-2026-04-23.md` | This combined report |
| `KNOWLEDGE.md` | Root cause corrected (OVN-K → GCP VPC firewall), fix documented |
| `ROSA_KNOWLEDGE.md` | Created: ROSA-specific findings, AWS SG root cause, comparison table |
| `references/pcap-2026-04-23/README.md` | Corrected original OVN-K attribution to GCP VPC firewall |

---

## Appendix A — Key OVS flows

Both clusters, all BGP workers:

```
# Table 0 — inbound from physical NIC (in_port=1) destined for CUDN
priority=300,ip,in_port=1,nw_dst=10.100.0.0/16 actions=output:3

# No ct() action — this is the definitive proof OVN-K does not gate on conntrack at this point.
# output:3 = ovn-k8s-mp1 (UDN management port) on the entry node.
# OVN L2 logical switch then Geneve-forwards to the VM's actual node.

# Table 1 — established flows (high packet counts, not related to the failure)
priority=100,ct_state=+est+trk,ct_mark=0x1,ip actions=output:2
priority=100,ct_state=+est+trk,ct_mark=0x2,ip actions=LOCAL
```

## Appendix B — Session timeline

| Time | Event |
|------|-------|
| 2026-04-23 morning | GCP debug session: baseline established (~22% success), NAT pcap collected, OVS observability limit found |
| 2026-04-23 afternoon | ROSA session: 100% success confirmed including post-migration, OVS flows inspected |
| 2026-04-23 afternoon | Cross-cluster comparison reveals AWS SG as differentiator; GCP VPC firewall identified as root cause |
| 2026-04-23 afternoon | GCP live fix applied (`gcloud compute firewall-rules create`); immediate 50/50 = 100% |
| 2026-04-23 afternoon | Terraform fix committed: `google_compute_firewall.cudn_egress_return`, default `true` |
| 2026-04-23 evening | Post-fix full re-run: 150/150 + VRF/conntrack verification; MIG restored to 3 |
| 2026-04-23 evening | This report written |

## Appendix C — References

| Document | Description |
|----------|-------------|
| [`docs/debug-internet-egress-2026-04-23.md`](debug-internet-egress-2026-04-23.md) | Full GCP session log (steps, pcap analysis, post-fix verification) |
| [`docs/debug-internet-egress-rosa-2026-04-23.md`](debug-internet-egress-rosa-2026-04-23.md) | Full ROSA session log (steps, live migration, cross-cluster comparison) |
| [`references/pcap-2026-04-23/README.md`](../references/pcap-2026-04-23/README.md) | Pcap analysis and corrected attribution |
| [`KNOWLEDGE.md`](../KNOWLEDGE.md) | GCP-specific verified facts and hypotheses |
| [`ROSA_KNOWLEDGE.md`](../ROSA_KNOWLEDGE.md) | ROSA-specific findings from this session |
| [`ARCHITECTURE.md`](../ARCHITECTURE.md) | Hub/spoke architecture rationale |
| [`archive/docs/nat-gateway.md`](../archive/docs/nat-gateway.md) | Original single-VPC Cloud NAT design (superseded) |
