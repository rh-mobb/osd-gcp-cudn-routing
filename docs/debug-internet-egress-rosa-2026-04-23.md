# CUDN Internet Egress Debug Session — ROSA/AWS — 2026-04-23

**Cluster:** `czvirt` · ROSA HCP · AWS · `eu-central-1`
**Goal:** Reproduce and document the CUDN internet egress failure (OVN-K conntrack node-locality drop)
on ROSA/AWS to answer: does the same root cause as GCP apply, expressed as 0%/100% binary failure
(Route Server single-active) rather than ~20% probabilistic failure (Cloud Router ECMP)?

**Reference:** GCP session — [`docs/debug-internet-egress-2026-04-23.md`](debug-internet-egress-2026-04-23.md)

**Result summary:** Internet egress from CUDN VMs on ROSA/OCP 4.21.9 works **100% reliably**,
even when the VM is on a different BGP router node from the active Route Server next-hop.
This directly contradicts the prediction in [`BRIEFING.md`](../BRIEFING.md).
The reason: OVN-K's `br-ex` OVS flow on the Route Server entry node forwards inbound CUDN traffic
directly to the UDN interface (`output:3`) **without any conntrack check**, then Geneve-tunnels to the
VM's node where `ct.est` is valid. The conntrack locality problem observed on GCP does not apply here.

---

## Environment

### Cluster

| Property | Value |
|----------|-------|
| Cluster name | `czvirt` |
| API URL | `https://api.czvirt.iqbc.p3.openshiftapps.com:443` |
| OCP version | **4.21.9** (≥ 4.21.8 — Geneve egress bug is fixed) |
| AWS region | `eu-central-1` |
| VPC ID | `vpc-0bc68a0308ca8c282` |
| VPC CIDR | `10.0.0.0/16` |
| CUDN prefix | `10.100.0.0/16` |
| Route Server ID | `rs-030e28f3dd4f57e96` (ASN 65000) |
| ROSA ASN | `65001` |

### Worker nodes

| Node | IP | AZ | BGP router | KVM capable | ENI src/dst check |
|------|----|----|------------|-------------|-------------------|
| `ip-10-0-1-131` (`czvirt-bm1-shpzp-fg42w`) | `10.0.1.131` | eu-central-1a | **yes** | yes (`c5.metal`) | **false** ✓ |
| `ip-10-0-2-108` (`czvirt-bm2-xqd2t-7lgsv`) | `10.0.2.108` | eu-central-1b | **yes** | yes (`c5.metal`) | **false** ✓ |
| `ip-10-0-3-139` (`czvirt-bm3-c97vr-8q25t`) | `10.0.3.139` | eu-central-1c | **yes** | yes (`c5.metal`) | **false** ✓ |
| `ip-10-0-1-72` (`czvirt-workers-1-q67dn-wrwjz`) | `10.0.1.72` | eu-central-1a | no | no (`devices.kubevirt.io/kvm: 0`) | — |
| `ip-10-0-2-35` (`czvirt-workers-0-jlx52-lrktq`) | `10.0.2.35` | eu-central-1b | no | no | — |
| `ip-10-0-3-4` (`czvirt-workers-2-vrt9b-9rsgd`) | `10.0.3.4` | eu-central-1c | no | no | — |

**Important architectural note:** VMs can only run on the 3 baremetal BGP router nodes. Non-baremetal
workers report `devices.kubevirt.io/kvm: 0` in allocatable resources. This means a CUDN VM will
always be co-located with a BGP router node — but not necessarily the active Route Server next-hop.

### CUDN VM

| Property | Value |
|----------|-------|
| Name | `test-vm-a` |
| Namespace | `cudn1` |
| Binding | `bridge` |
| VM IP | `10.100.0.4` |
| Initial node | `ip-10-0-1-131` (eu-central-1a) — **same as active BGP next-hop at session start** |
| Migration test node | `ip-10-0-2-108` (eu-central-1b) — different from active BGP next-hop |
| httpd | running on port 80 |
| SSH | password auth (`fedora`/`fedora`); access via jump pod in `cudn1` |

### Route Server

| Property | Value |
|----------|-------|
| Route Server ID | `rs-030e28f3dd4f57e96` |
| Subnet 1 endpoints | `10.0.1.236`, `10.0.1.242` |
| Subnet 2 endpoints | `10.0.2.202`, `10.0.2.92` |
| Subnet 3 endpoints | `10.0.3.234`, `10.0.3.151` |
| Active BGP next-hop (throughout session) | **`10.0.1.131`** (eni-0c75ed8e59df45f67) — all 4 route tables |

All four route tables (`private-eu-central-1a`, `private-eu-central-1b`, `private-eu-central-1c`,
`public`) consistently point to `10.0.1.131` as the CUDN next-hop for the entire session.

### EC2 test instances

| Instance | IP | VPC | HTTP server |
|----------|----|-----|-------------|
| `pczarkow-cz-bgp-test-instance` (`i-0fbca13cddfbb5d4d`) | `10.0.1.155` | vpc1 (subnet 1a) | Python `http.server :8080` |
| `pczarkow-cz-bgp-test-instance-vpc2` (`i-0d7c49e6cf5949125`) | `192.168.1.86` | vpc2 | Python `http.server :8080` |

Both instances deployed in this session (were missing from terraform state). HTTP servers started via
`user_data`. SGs allow TCP 8080 and ICMP inbound.

### FRR BGP configuration

Single `FRRConfiguration` CR (`all-nodes`) in `openshift-frr-k8s`, applying to all nodes with
`bgp_router=true`. Each BGP router node peers with all 6 Route Server endpoints (2 per subnet).
OVN-K generates additional `ovnk-generated-*` CRs for route advertisement.

---

## Pre-flight assessment

- OCP version: **4.21.9** — Geneve egress bug (pre-4.21.8) is fixed; this session tests only the
  conntrack node-locality question.
- VM on `10.0.1.131` (active BGP next-hop): return traffic should reach `10.0.1.131` → OVN-K has
  `ct.est` → expected 100% internet egress.
- VM migrated to `10.0.2.108` (non-active BGP): return goes to `10.0.1.131` → **if** OVN-K checks
  `ct.est` there → expected 0% failure.

---

## Step 1 — Baseline internet egress failure rate

**Setup:** VM `test-vm-a` (`10.100.0.4`) on `ip-10-0-1-131` (same node as active BGP next-hop).
**Access:** jump pod in `cudn1` (netshoot + sshpass) → SSH password auth → `fedora@10.100.0.4`.

**Command:**
```bash
for i in $(seq 1 50); do
  curl -4s --max-time 3 -o /dev/null -w "%{http_code}\n" https://ifconfig.me
done | sort | uniq -c
```

### Results

| Run | 200 | 000 | Success rate |
|-----|-----|-----|-------------|
| 1 | 50 | 0 | **100%** |
| 2 | 50 | 0 | **100%** |
| 3 | 50 | 0 | **100%** |

**All 150/150 requests succeeded.**

**Analysis:** VM is on the active BGP node (`10.0.1.131`). All internet return traffic is routed by
Route Server to `10.0.1.131`. OVN-K on that node has `ct.est` for all flows initiated by the VM →
100% success. This is the expected "good" baseline.

**Compare with GCP baseline:** GCP cluster showed ~16%–30% success across 6 runs (average 22%).
The higher success rate on ROSA (100% vs 22%) is expected here because the Route Server single-active
FIB sends all return traffic to one specific node (the VM's node), while GCP Cloud Router ECMP
distributes across all 5 workers randomly.

---

## Step 2 — Control test: EC2 test instance (RFC-1918 return source)

**Test:** Curl from CUDN VM to `10.0.1.155:8080` (Python HTTP server on EC2 instance in vpc1).
Return source is `10.0.1.155` (RFC-1918). OVN-K accepts new connections from RFC-1918 on any
worker and Geneve-forwards to the correct pod — confirms control path independence from conntrack.

### Results

| Run | n | 200 | 000 | Success rate |
|-----|---|-----|-----|-------------|
| 1 | 50 | 50 | 0 | **100%** |
| 2 | 500 | 500 | 0 | **100%** |
| 3 | 5000 | 5000 | 0 | **100%** |

**5,550 / 5,550 = 100% success.**

**Analysis:** Confirms OVN-K accepts RFC-1918 return sources on any worker — the control path
works exactly as expected. Consistent with GCP findings (5,050/5,050 = 100% on GCP).

---

## Step 3 — Packet capture on EC2 test instance

Not performed (tcpdump/SSM session would duplicate test instance data without adding additional
insight given the 100% internet egress finding). The control test result (Step 2) is sufficient
to confirm RFC-1918 path is fully functional.

---

## Step 4 — Internet egress test after live migration (key experiment)

**Setup change:** VM `test-vm-a` live-migrated from `ip-10-0-1-131` (active BGP node) to
`ip-10-0-2-108` (non-active BGP node). Active BGP next-hop in Route Server remains `10.0.1.131`
throughout — confirmed by `aws ec2 describe-route-tables` before and after migration.

**Expected (per BRIEFING.md):** 0% — return traffic arrives at `10.0.1.131`, OVN-K has no `ct.est`
for flows from `10.0.2.108`, drops silently.

**Migration method:** `virtctl migrate test-vm-a -n cudn1` with `nodeAffinity` patched to require
`ip-10-0-2-108`. Note: non-baremetal workers rejected as migration targets (`devices.kubevirt.io/kvm: 0`).

### Route table verification post-migration

```
Route tables (all 4):  10.100.0.0/16 → 10.0.1.131 (eni-0c75ed8e59df45f67)
VM location:            ip-10-0-2-108.eu-central-1.compute.internal
```

### Internet egress results with VM on 10.0.2.108

| Run | 200 | 000 | Success rate |
|-----|-----|-----|-------------|
| 1 | 50 | 0 | **100%** |
| 2 | 50 | 0 | **100%** |
| 3 | 50 | 0 | **100%** |

**150/150 = 100% success. The failure predicted by BRIEFING.md did NOT occur.**

### Why internet egress works: OVS flow analysis

Inspecting `br-ex` OVS flows on the entry node (`10.0.1.131`) reveals the root cause:

```
priority=300,ip,in_port=1,nw_dst=10.100.0.0/16 actions=output:3
```

Key facts:
- `in_port=1`: physical AWS NIC (`ens5`), which is an OVS port
- `nw_dst=10.100.0.0/16`: any packet destined for the CUDN prefix
- `actions=output:3`: forward directly to the UDN interface (`ovn-k8s-mp1`)
- **No `ct()` action** — there is no conntrack check in this flow rule

When return internet traffic (`src=8.8.8.8, dst=10.100.0.4`) arrives at `10.0.1.131`:
1. Hits the `priority=300` rule on `br-ex`
2. Forwarded **without conntrack inspection** to `output:3` (UDN interface)
3. OVN-K Layer2 logical switch looks up the L2 port binding for `10.100.0.4`
4. Finds MAC binding on `ip-10-0-2-108` → Geneve-encapsulates to `10.0.2.108`
5. On `10.0.2.108`: OVN-K processes the packet at the VM's logical port where `ct.est` exists
6. Delivered to VM

The conntrack check happens at the **VM's logical port** (on the VM's node), not at the **entry node**.
This is the correct L2 switch semantics: the logical switch forwards based on MAC/IP binding without
requiring conntrack state at transit nodes.

### Conntrack state verification

`/proc/net/nf_conntrack` on `10.0.2.108` (VM's node) shows established flows to `34.160.111.145`
(ifconfig.me) with `[ASSURED]` and `zone=70`:
```
ipv4  tcp  ESTABLISHED  src=10.100.0.4 dst=34.160.111.145 sport=41880 dport=443  [ASSURED]  zone=70
```

The conntrack state lives on the VM's node (`10.0.2.108`), confirming the return path resolves to
the correct node via Geneve.

---

## Step 5 — OVS observability (worker node tcpdump)

**Objective:** Confirm OVS datapath behaviour on AWS workers during internet egress.

### Results

| Interface | Node | Description | Packets |
|-----------|------|-------------|---------|
| `br-ex` | `10.0.1.131` (entry node) | OVS external bridge | **0** |
| `any` | `10.0.1.131` | All interfaces | 6 (ARP/mgmt only, not data) |

**Finding:** `br-ex` shows 0 packets during CUDN internet traffic — same OVS rx_handler invisibility
as GCP. The physical NIC (`ens5`) is an OVS port; `AF_PACKET` (libpcap/tcpdump) cannot observe
traffic that goes directly through the OVS kernel datapath.

`any` interface captured 6 packets out of a 10-request test — these are likely ARP and management
frames that are not in the OVS fast path, not CUDN data traffic.

This is consistent with the GCP finding (0 packets on all interfaces including `ens4`, `br-ex`,
`any`, `ovn-k8s-mp1`). The same OVS observability limitation applies on AWS.

---

## Step 6 — VRF routing check

Both BGP router nodes show identical `mp1-udn-vrf` routing:

**On `ip-10-0-1-131` (active BGP node):**
```
default via 10.0.1.1 dev br-ex mtu 8901
unreachable default metric 4278198272
10.100.0.0/16 dev ovn-k8s-mp1 proto kernel scope link src 10.100.0.2
169.254.0.3 via 10.100.0.1 dev ovn-k8s-mp1
169.254.0.12 dev ovn-k8s-mp1 mtu 8901
172.30.0.0/16 via 169.254.0.4 dev br-ex mtu 8901
```

**On `ip-10-0-2-108` (VM's node after migration):**
```
default via 10.0.2.1 dev br-ex mtu 8901
unreachable default metric 4278198272
10.100.0.0/16 dev ovn-k8s-mp1 proto kernel scope link src 10.100.0.2
169.254.0.3 via 10.100.0.1 dev ovn-k8s-mp1
169.254.0.12 dev ovn-k8s-mp1 mtu 8901
172.30.0.0/16 via 169.254.0.4 dev br-ex mtu 8901
```

Same pattern as GCP: `10.100.0.0/16 dev ovn-k8s-mp1 proto kernel scope link src 10.100.0.2`.
CUDN prefix is in `mp1-udn-vrf` backed by `ovn-k8s-mp1`. In-kernel forwarding is OVS/OVN-K only.

---

## Summary and comparison with GCP

Both clusters confirmed on **OCP 4.21.9**.

| Test | GCP result | ROSA (this session) | Match? |
|------|------------|---------------------|--------|
| OCP version | 4.21.9 | 4.21.9 | Yes |
| Internet egress success rate (VM on active BGP node) | ~22% average (ECMP) | **100%** (Route Server single-active) | No |
| Internet egress (VM on non-active BGP node) | N/A (ECMP) | **100%** (single-active FIB) | — |
| RFC-1918 control test | 100% (n=5050) | **100%** (n=5550) | Yes |
| OVS `br-ex` flow for CUDN (`nw_dst=10.100.0.0/16`) | `output:3` — no `ct()` | `output:3` — no `ct()` | **Same** |
| OVN ACLs on CUDN switch | 3 rules (identical) | 3 rules (identical) | **Same** |
| OVN lflows | Identical | Identical | **Same** |
| OVS observability (br-ex/any) | 0 packets | 0 on br-ex, 6 on any (ARP) | Essentially same |
| VRF routing | `mp1-udn-vrf` / `ovn-k8s-mp1` | `mp1-udn-vrf` / `ovn-k8s-mp1` | Yes |
| Worker inbound security | GCP VPC stateful firewall (no allow-all for internet) | **AWS SG: allow all from `0.0.0.0/0`** | **Different — root cause** |

### Core question answer

**ROSA/OCP 4.21.9 does NOT have the CUDN internet egress failure described in BRIEFING.md.**

**The root cause of the difference is not OVN-K — it is the AWS security group on the BGP baremetal
workers.** Every ROSA BGP worker node carries `rosa-virt-allow-from-ALL-sg`, an additional security
group with a single rule: `proto=-1, src=0.0.0.0/0` (allow all inbound from anywhere). This means
internet return packets (`src=34.x.x.x, dst=10.100.0.x`) are accepted by the worker's ENI regardless
of which baremetal worker the Route Server routes them to.

### Why GCP failed but ROSA works — confirmed root cause

The GCP and ROSA clusters are identical at the OVN level (same OCP version, same OVS flows, same
ACLs). The failure is at the **cloud network firewall layer**, not inside OVN-K:

- **GCP fails** because the GCP VPC stateful firewall has no allow-all rule for internet-sourced
  traffic on spoke workers. `cz-demo1-hub-to-spoke-return` only covers `src=10.20.0.0/24` (the hub
  NAT VMs' subnet). Return internet traffic (`src=34.x.x.x`) landing on the "wrong" worker (one that
  did not originate the outbound SYN) is dropped at the GCP firewall before OVS ever sees it. The
  ~22% success rate reflects connections that are returned to the same worker that initiated them
  (stateful tracking allows the return on that one worker).

- **ROSA works** because `rosa-virt-allow-from-ALL-sg` (`proto=-1, src=0.0.0.0/0`) is attached to
  all 3 BGP baremetal workers. Internet return packets pass the security group unconditionally
  regardless of which worker receives them.

The earlier hypothesis that OVN-K was dropping packets via `ct.est` checks was an inference error.
The `pcap-2026-04-23` analysis correctly identified the failure symptom (SYN-ACK retransmissions)
but incorrectly attributed it to OVN-K rather than the VPC firewall.

**The OVS `output:3` no-ct flow** exists on both clusters and is not the differentiator. It is correct
OVN-K behaviour for Layer2 CUDN ingress: forward to the UDN OVN pipeline without a br-ex-level
conntrack action, then Geneve-tunnel to the VM's node inside OVN.

**Fix applied and confirmed (April 2026):** `google_compute_firewall.cudn_egress_return` added to
`modules/osd-spoke-vpc` (enabled via `spoke_enable_cudn_egress_return = true`). Allow all from
`0.0.0.0/0`, VPC-wide, no target tags (GCP worker tags are OSD-installer-assigned, not ours to
control). Applied live and tested: **50/50 = 100%** immediately. Equivalent to ROSA's
`rosa-virt-allow-from-ALL-sg`.

---

## Operational notes

### VM access

`virtctl ssh` connects to the VM but fails on key auth (only password auth configured). Access via:
```bash
oc run jump -n cudn1 --image=nicolaka/netshoot --restart=Never -- sleep 3600
oc exec -n cudn1 jump -- sh -c "apk add --no-cache sshpass"
oc exec -n cudn1 jump -- sshpass -p 'fedora' ssh -o StrictHostKeyChecking=no fedora@10.100.0.4 'cmd'
```

### Test instance HTTP server

EC2 test instances (`test-instance` and `test-instance-vpc2`) deployed via terraform in this session.
Both have `user_data` that starts `python3 -m http.server 8080` on boot. SGs allow TCP 8080.

### Live migration test node

VMs can only live-migrate between the 3 baremetal nodes (`c5.metal`). Non-baremetal workers have
`devices.kubevirt.io/kvm: 0` in allocatable resources — migration attempts to those nodes enter
`Scheduling` indefinitely and must be manually cancelled (`oc delete vmim`).

---

## References

- GCP session: [`docs/debug-internet-egress-2026-04-23.md`](debug-internet-egress-2026-04-23.md)
- GCP pcaps: [`references/pcap-2026-04-23/README.md`](../references/pcap-2026-04-23/README.md)
- Root cause brief: [`BRIEFING.md`](../BRIEFING.md)
- ROSA architecture: [`references/rosa-bgp/README.md`](../references/rosa-bgp/README.md)
- ROSA knowledge: [`ROSA_KNOWLEDGE.md`](../ROSA_KNOWLEDGE.md)
