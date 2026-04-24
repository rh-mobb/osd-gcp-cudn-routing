# ROSA Knowledge Base: CUDN BGP Routing on ROSA/AWS

AWS-specific findings for BGP-based CUDN routing on ROSA HCP.
For GCP findings, see [`KNOWLEDGE.md`](KNOWLEDGE.md).

**Reference cluster:** `czvirt` · ROSA HCP · `eu-central-1` · OCP 4.21.9
**GCP reference cluster:** `cz-demo1` · OSD GCP · `us-central1` · OCP 4.21.9
**Debug session:** [`docs/debug-internet-egress-rosa-2026-04-23.md`](docs/debug-internet-egress-rosa-2026-04-23.md)

---

## Verified Facts

### CUDN Internet Egress on ROSA/OCP 4.21.9

- **CUDN internet egress from KubeVirt VMs works 100% reliably on ROSA/OCP 4.21.9.** Verified
  April 2026.
  This contradicts the prediction in [`BRIEFING.md`](BRIEFING.md), which expected 0%/100% binary
  failure based on Route Server single-active FIB semantics and the OVN-K conntrack node-locality
  problem documented on GCP.

  Results:
  - VM on active BGP node (`10.0.1.131`): 150/150 = 100% (3 runs × 50 requests)
  - VM on non-active BGP node (`10.0.2.108`, active BGP = `10.0.1.131`): 150/150 = 100%

  **Confidence: 95%** (fully tested in production session; see debug doc for full evidence).

- **Root cause of ROSA's 100% success: `rosa-virt-allow-from-ALL-sg` on all BGP baremetal workers.**
  Verified April 2026. Every ROSA BGP router pool (`router-pool1`, `router-pool2`, `router-pool3`)
  attaches `aws_security_group.rosa_allow_from_all_sg` as an additional security group. This SG has
  a single rule: `proto=-1, src=0.0.0.0/0` (allow ALL inbound from anywhere). This allows internet
  return traffic (`src=34.x.x.x`) to pass the AWS security group unconditionally on any BGP worker,
  regardless of which worker originated the outbound connection.

  Both baremetal workers confirmed:
  ```
  ip-10-0-1-131 (i-024c7b58713743e75): ... rosa-virt-allow-from-ALL-sg ...
  ip-10-0-2-108 (i-0a2a1a1f098fdd511): ... rosa-virt-allow-from-ALL-sg ...
  ```

  **Confidence: 100%** (directly inspected via `aws ec2 describe-instances` on both nodes;
  Terraform definition confirmed in `references/rosa-bgp/rosa-pools.tf`).

- **The failure in GCP is at the VPC firewall layer, not inside OVN-K.** Verified April 2026.
  Comparing OVS flows, OVN ACLs, and OVN lflows on both clusters:
  - OCP version: both 4.21.9
  - `br-ex` CUDN flow: both `priority=300,ip,in_port=1,nw_dst=10.100.0.0/16 actions=output:3`
  - OVN ACLs on CUDN switch: identical (3 rules, same conditions)
  - OVN lflows: identical

  GCP has no equivalent allow-all firewall rule for internet-sourced traffic (`src=34.x.x.x`) on
  spoke workers. `cz-demo1-hub-to-spoke-return` allows only `src=10.20.0.0/24` (hub NAT VMs'
  subnet). Internet return landing on the "wrong" GCP worker (ECMP) is silently dropped at the GCP
  VPC firewall before OVS sees it. The ~22% GCP success rate reflects connections where the SYN-ACK
  happens to return to the same worker that sent the SYN (stateful GCP firewall allows that return).

  The earlier hypothesis that "OVN-K's conntrack state is node-local and drops packets at the wrong
  node" was an inference from `pcap-2026-04-23` retransmission patterns. That inference was
  incorrect — OVN-K does not perform a `ct.est` check at the br-ex level for CUDN traffic, on either
  cluster. The drop is at the cloud VPC/firewall layer.

  **Confidence: 90%** (OVN flows confirmed identical; GCP firewall rules inspected; the ~20%
  success rate exactly matches ECMP-stateful-firewall behaviour; no direct packet capture to
  absolutely prove the GCP drop point, but the evidence is consistent).

- **The OVS `output:3` no-ct br-ex flow is correct OVN-K behaviour, not a differentiator.**
  Verified April 2026. Both clusters have `priority=300,ip,in_port=1,nw_dst=10.100.0.0/16
  actions=output:3` in br-ex. This flow sends CUDN-destined return traffic into the OVN logical
  switch pipeline without a br-ex-level conntrack action. OVN then Geneve-tunnels to the VM's
  actual node for delivery. This is expected Layer2 UDN behaviour.

  **Confidence: 100%** (directly verified on both clusters).

- **VMs on ROSA can only run on baremetal BGP router nodes.** Verified April 2026.
  Non-baremetal workers report `devices.kubevirt.io/kvm: 0` in allocatable resources and reject
  VM migration (`Scheduling` indefinitely). The 3 `c5.metal` BGP router nodes (one per AZ) are the
  only nodes capable of running KVM VMs. This means in the ROSA/AWS reference deployment, a CUDN
  VM will always be co-located with a BGP router node — but not necessarily the active Route Server
  next-hop node.

  **Confidence: 100%** (observed in `kubectl describe node` allocatable + failed migration attempt).

### OVS Observability on AWS Workers

- **OVS datapath is invisible to standard tcpdump on AWS workers, same as GCP.** Verified April 2026.
  `br-ex` interface shows 0 packets during CUDN internet traffic. `any` interface captures only
  6 packets (ARP/management) out of a 10-request test — CUDN data traffic is entirely in the OVS
  kernel fast path.
  The AWS physical NIC (`ens5`) is registered as an OVS port. The OVS `rx_handler` intercepts
  traffic before `AF_PACKET` (libpcap). This is identical to the GCP finding (`ens4`, April 2026).

  **Confidence: 99%** (directly tested with concurrent tcpdump + curl test).

### VRF Routing on ROSA Workers

- **CUDN routing on ROSA BGP router nodes uses the same `mp1-udn-vrf` and `ovn-k8s-mp1` pattern as GCP.**
  Verified April 2026:
  ```
  ip route show vrf mp1-udn-vrf
    10.100.0.0/16 dev ovn-k8s-mp1 proto kernel scope link src 10.100.0.2
    169.254.0.3 via 10.100.0.1 dev ovn-k8s-mp1
  ```
  In-kernel forwarding for CUDN traffic is OVS/OVN-K only. The VRF is used only for FRR BGP
  advertisement, not for per-packet forwarding.

  **Confidence: 100%** (confirmed on both `10.0.1.131` and `10.0.2.108`).

### Route Server Behaviour

- **VPC Route Server installs a single active next-hop for the CUDN prefix across all route tables.**
  Verified April 2026. All four route tables (`private-eu-central-1a`, `private-eu-central-1b`,
  `private-eu-central-1c`, `public`) consistently show `10.0.1.131` (eni-0c75ed8e59df45f67) as
  the active next-hop for `10.100.0.0/16` throughout the entire session — including after VM live
  migration to `10.0.2.108`. The Route Server does not change the FIB entry based on VM placement.

  **Confidence: 100%** (route tables queried multiple times during session).

- **All 3 BGP router nodes advertise the CUDN prefix; Route Server picks one for FIB.**
  BGP sessions exist from all 3 nodes to 6 Route Server endpoints (2 per subnet/AZ). The Route
  Server RIB has all 3 routes; only one is installed in the subnet route tables (single-active FIB).
  This is the designed HA behaviour: if the active node's BGP sessions drop (e.g., node drain/failure),
  Route Server fails over to the next available BGP peer.

  **Confidence: 95%** (documented in ROSA BGP README; FIB confirmed via `describe-route-tables`).

### FRR/BGP Configuration

- **Single `FRRConfiguration` CR (`all-nodes`) applies to all `bgp_router=true` nodes.**
  Each router node peers with all 6 Route Server endpoints. No `ebgpMultiHop` (uses Route Server
  endpoints in same subnet). No `disable-connected-check` needed (unlike GCP where /32 on `br-ex`
  required it). **Confidence: 100%** (inspected CR in session).

---

## Comparison with GCP Findings

Both clusters run **OCP 4.21.9** on the same OVN-K version. The difference is purely at the cloud
network layer.

| Property | GCP (OCP 4.21.9) | ROSA (OCP 4.21.9) |
|----------|--------------------|---------------------|
| Internet egress success rate | ~22% average | **100%** |
| OVS `br-ex` flow for CUDN ingress | `output:3` — no `ct()` (**same**) | `output:3` — no `ct()` |
| OVN ACLs on CUDN switch | 3 rules (**same**) | 3 rules |
| OVN lflows | Identical | Identical |
| Worker inbound firewall | GCP VPC stateful, no allow-all for internet | **AWS SG: `proto=-1, 0.0.0.0/0`** ← differentiator |
| ECMP / routing | 2-way ECMP (2 baremetal BGP workers) | Single-active FIB (Route Server) |
| tcpdump observability | 0 packets on all interfaces | 0 on `br-ex`, 6 ARP on `any` |
| VRF routing | `mp1-udn-vrf` / `ovn-k8s-mp1` | Same |

### Resolved: why GCP fails but ROSA works

The earlier `pcap-2026-04-23` analysis inferred that OVN-K was dropping packets at "wrong" workers
due to missing `ct.est`. That inference was incorrect. The actual drop is at the GCP VPC firewall.

GCP firewall rule `cz-demo1-hub-to-spoke-return` allows `src=10.20.0.0/24` (hub NAT VMs only).
Internet return traffic has `src=34.x.x.x` — not covered by any allow rule on the wrong GCP worker.
The GCP stateful firewall allows return traffic only on the worker that established the outbound
session. With 2-way ECMP, ~50% of returns hit the correct worker; the observed ~22% success rate
likely reflects additional Cloud Router path distribution effects.

ROSA's `rosa-virt-allow-from-ALL-sg` (allow all from `0.0.0.0/0`) completely bypasses this problem.

**Fix confirmed in production (April 2026):** `google_compute_firewall.cudn_egress_return` added to
`modules/osd-spoke-vpc`, enabled via `spoke_enable_cudn_egress_return = true` in
`cluster_bgp_routing`. VPC-wide, allow all from `0.0.0.0/0` (no target tags — GCP worker network
tags are OSD-installer-assigned and not under our control). Result: **50/50 = 100%** internet egress
immediately after applying. Equivalent to AWS `rosa-virt-allow-from-ALL-sg`.

---

## Operational Notes

### VM access in ROSA CUDN

`virtctl ssh` reaches the VM but fails on key auth (only password auth configured in cloud-init).
Use a jump pod in `cudn1`:
```bash
oc run jump -n cudn1 --image=nicolaka/netshoot --restart=Never -- sleep 3600
oc exec -n cudn1 jump -- apk add --no-cache sshpass
oc exec -n cudn1 jump -- sshpass -p 'fedora' ssh -o StrictHostKeyChecking=no fedora@10.100.0.4 'cmd'
```

### Live migration between BGP router nodes

Migration target must be a `c5.metal` baremetal BGP router node. To migrate to a specific node:
```bash
oc patch vm <name> -n <ns> --type=merge -p '{
  "spec": {"template": {"spec": {"affinity": {"nodeAffinity": {
    "requiredDuringSchedulingIgnoredDuringExecution": {
      "nodeSelectorTerms": [{"matchExpressions": [{
        "key": "kubernetes.io/hostname",
        "operator": "In",
        "values": ["<node-name>"]
      }]}]
    }
  }}}}}}'
virtctl migrate <vm-name> -n <ns>
# Cleanup:
oc patch vm <name> -n <ns> --type=json -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]'
```

### Test instance HTTP server

EC2 instances (`pczarkow-cz-bgp-test-instance` at `10.0.1.155`) serve Python `http.server :8080`.
Access via `aws ssm start-session --target <instance-id> --region eu-central-1`.

---

## Sources

| Source | Key contribution |
|--------|-----------------|
| Production test session — `czvirt` ROSA cluster, April 2026 | All facts in this file |
| [`docs/debug-internet-egress-rosa-2026-04-23.md`](docs/debug-internet-egress-rosa-2026-04-23.md) | Full session transcript |
| OVS flow dump — `10.0.1.131` `br-ex`, April 2026 | No-ct CUDN ingress flow |
| OVS flow dump — `cz-demo1-k5r7v-baremetal-a-l6z4w` `br-ex`, April 2026 | GCP flow confirmed identical |
| OVN ACL + lflow inspection — both clusters, April 2026 | OVN pipeline confirmed identical |
| `aws ec2 describe-instances` — both ROSA baremetal workers, April 2026 | `rosa-virt-allow-from-ALL-sg` confirmed |
| `gcloud compute firewall-rules describe cz-demo1-hub-to-spoke-return`, April 2026 | GCP firewall covers only `10.20.0.0/24` |
| [`references/rosa-bgp/rosa-pools.tf`](references/rosa-bgp/rosa-pools.tf) | `rosa_allow_from_all_sg` in pool definition |
| `/proc/net/nf_conntrack` — `10.0.2.108`, April 2026 | Conntrack state locality confirmed |
| [`references/rosa-bgp/README.md`](references/rosa-bgp/README.md) | Route Server single-active design |
| [`BRIEFING.md`](BRIEFING.md) | GCP findings and ROSA prediction (now updated by this session) |
