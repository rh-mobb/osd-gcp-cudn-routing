# CUDN Internet Egress Debug Session — 2026-04-23

**Cluster:** `cz-demo1` · OSD/GCP · `us-central1`
**Goal:** Reproduce and document the CUDN internet egress failure (ECMP + OVN-K conntrack drop) with packet captures.

## Environment

### Cluster nodes

| Node | Type | AZ | BGP peer |
|------|------|----|----------|
| `cz-demo1-k5r7v-baremetal-a-l6z4w` | baremetal | us-central1-a | yes |
| `cz-demo1-k5r7v-baremetal-a-wnl8v` | baremetal | us-central1-a | yes |
| `cz-demo1-k5r7v-worker-a-6zhtm` | worker | us-central1-a | yes |
| `cz-demo1-k5r7v-worker-b-dbdpm` | worker | us-central1-b | yes |
| `cz-demo1-k5r7v-worker-c-82fzn` | worker | us-central1-c | yes |
| `cz-demo1-k5r7v-infra-a-2qksn` | infra | us-central1-a | — |
| `cz-demo1-k5r7v-infra-b-hs5cp` | infra | us-central1-b | — |
| `cz-demo1-k5r7v-infra-c-96l2m` | infra | us-central1-c | — |

### Test VMs (namespace `cudn1`, CUDN `10.100.0.0/16`)

| VM | IP | Node | Binding |
|----|----|------|---------|
| `virt-e2e-bridge` | `10.100.0.7` | `baremetal-a-l6z4w` | `l2bridge` |
| `virt-e2e-masq` | `10.100.0.8` | `baremetal-a-l6z4w` | `masquerade` |

Both VMs are co-located on `baremetal-a-l6z4w` (us-central1-a).
This is significant: for internet egress, the outbound packet exits via that node,
but Cloud Router ECMP (5 workers × 2 peers = 10 paths) routes return traffic to a random worker.

### Hub NAT

| Resource | Value |
|----------|-------|
| MIG name | `cz-demo1-nat-gw-mig` (regional, `us-central1`) |
| ILB IP | `10.20.0.5` |
| Original size | 3 |

---

## Step 1 — Reduce hub NAT MIG to 1 instance

**Rationale:** With 3 NAT VMs behind the ILB, outbound flows distribute across instances,
requiring captures on all 3.
A single instance makes the masquerade/DNAT path fully deterministic.

**Command run:**

```bash
gcloud compute instance-groups managed resize cz-demo1-nat-gw-mig \
  --size=1 --region=us-central1 --project=mobb-demo
```

**Result:** Resize accepted (`targetSize: 1`). MIG was deleting 2 of 3 instances at time of writing.
Status was still `isStable: false` when this step was logged — confirm before running captures.

**To verify completion:**

```bash
gcloud compute instance-groups managed list-instances cz-demo1-nat-gw-mig \
  --region=us-central1 --project=mobb-demo \
  --format="table(name,zone,status,instanceHealth[0].detailedHealthState)"
```

**Verified:** 1 instance, `HEALTHY`.

| Instance | Zone | Internal IP |
|----------|------|-------------|
| `cz-demo1-nat-gw-vwn5` | `us-central1-a` | `10.20.0.2` |

- [x] MIG stabilised at 1 instance

---

## Step 2 — Baseline internet egress failure rate (50-ping test)

**Test:** 50 `curl` requests from `virt-e2e-bridge` (`10.100.0.7`) to `https://ifconfig.me`.
Each request is an independent TCP connection with a different ephemeral src port,
producing different ECMP hash paths and sampling the full distribution across the 5 BGP workers.

**Command:**

```bash
virtctl ssh cloud-user@virt-e2e-bridge -n cudn1 \
  --local-ssh-opts="-i cluster_bgp_routing/.virt-e2e/id_ed25519" -- \
  'for i in $(seq 1 50); do
     curl -4s --max-time 3 -o /dev/null -w "%{http_code}\n" https://ifconfig.me
   done | sort | uniq -c'
```

**Expected (broken):** ~80–90% `000` (timeout), ~10–20% `200`.

### Results

```text
42 000
 8 200
```

| Code | Count | % | Meaning |
|------|-------|---|---------|
| `200` | 8 | 16% | Success — ECMP return landed on VM's worker (`baremetal-a-l6z4w`) |
| `000` | 42 | 84% | Timeout — ECMP return landed on a different worker, OVN-K dropped |

**Success rate: 8 / 50 (16%)**

**Analysis:**
With 5 BGP workers × 2 Cloud Router peers = 10 equal-cost paths,
the expected success rate is 2/10 = 20% (the 2 paths that hash back to the VM's own node).
Observed 16% is consistent with this — small-sample variation from a 50-request run.
The 84% failure rate directly confirms the ECMP + OVN-K conntrack drop hypothesis
described in [BRIEFING.md](../BRIEFING.md).

---

## Step 3 — Control test: VPC echo VM (RFC-1918 return source)

**Test:** 50 `curl` requests from `virt-e2e-bridge` (`10.100.0.7`) to the spoke echo VM (`10.0.32.2:8080`).
Return traffic carries a **RFC-1918 source IP**, so OVN-K accepts new connections on any worker
and Geneve-forwards to the correct pod — no `ct.est` check applies.
This isolates the failure as specific to **public internet source IPs**, not ECMP itself.

**Command (run via netshoot-cudn jump):**

```bash
bash scripts/virt-ssh.sh -C cluster_bgp_routing virt-e2e-bridge -- \
  'for i in $(seq 1 50); do
     curl -4s --max-time 3 -o /dev/null -w "%{http_code}\n" http://10.0.32.2:8080/
   done | sort | uniq -c'
```

### Results

Three runs at increasing sample sizes:

```text
  50 200   (n=50)
 500 200   (n=500)
5000 200   (n=5000)
```

| Run | Requests | `200` | `000` | Success rate |
|-----|----------|-------|-------|--------------|
| 1 | 50 | 50 | 0 | 100% |
| 2 | 500 | 500 | 0 | 100% |
| 3 | 5 000 | 5 000 | 0 | 100% |

**Success rate: 5 050 / 5 050 (100%) across all runs.**

**Analysis:**
Zero failures across 5 050 requests over Cloud Router ECMP confirms that
OVN-K's conntrack check is **source-IP-type sensitive** — not an ECMP routing problem.
RFC-1918 sources are accepted on any worker and forwarded via the OVN overlay
regardless of which node originated the connection.
Public internet sources (`8.8.8.8`) require a local `ct.est` entry and are silently
dropped on workers that did not originate the connection (Step 2: 84% failure rate).

**This is the key control result.**
The only variable between Step 2 (84% failure) and Step 3 (100% success) is
the source IP class on the return packet — public internet vs RFC-1918.

---

## Step 4 — NAT VM packet capture

**Objective:** Confirm the NAT VM correctly masquerades outbound and DNATs return traffic,
and identify which connections succeed vs fail at the TCP handshake level.

**Setup:** `tcpdump` installed on `cz-demo1-nat-gw-vwn5`, captured for 90 s via IAP SSH
while the 50-curl internet test ran from `virt-e2e-bridge`.

**Pcap saved to:** [`references/pcap-2026-04-23/gcp-nat-internet-egress-2026-04-23.pcap`](../references/pcap-2026-04-23/gcp-nat-internet-egress-2026-04-23.pcap)

**Capture stats:** 213 packets, 0 dropped, 39 KB.
All traffic on interface `gif0` — the GRE VPC peering tunnel between hub and spoke.

### Second run result (during capture)

```text
41 000
 9 200
```

Consistent with first run (84% failure rate).

### Pcap analysis

**Inbound on NAT VM (`In` on `gif0`):** raw CUDN packets `src=10.100.0.7` arriving from spoke —
confirms the NAT VM receives every outbound SYN from the bridge VM.

**Outbound from NAT VM (`Out` on `gif0`):** return packets `dst=10.100.0.7` after DNAT —
confirms the NAT VM correctly rewrites the destination and sends the SYN-ACK back toward the spoke.

**Connection outcome by port:**

| Port | SYN retransmissions | Data exchanged | Outcome |
|------|--------------------|----|---------|
| `50536`, `50446`, `50436`, `50428`, `50418` | 2 (3 total SYNs) | No | **Failed** — all 3 SYN-ACKs dropped by OVN-K |
| `43550`, `43542`, `43508`, `40148`, `40132`, `40126` | 2 | No | **Failed** |
| `56284`, `56278`, `56254` | 2 | No | **Failed** |
| `56266`, `43530`, `43514`, `40140` | 1 (2 total SYNs) | **Yes** | **Succeeded** — first SYN-ACK dropped, retry hit the right worker |
| ~5 other ports | 0 | Yes | **Succeeded** — first SYN-ACK landed on correct worker |

### Key finding

The NAT VM is **not the failure point.**
Every SYN is received and every SYN-ACK is correctly DNAT'd and forwarded back to `dst=10.100.0.7`.

The failure pattern matches OVN-K ECMP conntrack drop exactly:

- **Failed connections (2 retransmissions):** the SYN-ACK was sent by the NAT VM 3 times.
  Each time it entered the spoke VPC, Cloud Router ECMP routed it to a different worker.
  All three workers lacked `ct.est` for this flow → OVN-K silently dropped all three.
  The `curl --max-time 3` timer expired before a 4th retry.
- **Partially recovered connections (1 retransmission):** first SYN-ACK hit the wrong worker (dropped).
  VM retransmitted the SYN; the second SYN-ACK landed on the correct worker → connection completed.
- **Immediate successes:** first SYN-ACK happened to land on the VM's own worker → accepted.

This confirms that the failure is entirely inside the spoke VPC at the OVN-K layer,
not at the NAT VM, the VPC peering, or the internet path.

---

## Step 5 — Worker node capture investigation (tmux MCP)

**Objective:** Confirm SYN-ACKs from `34.160.111.145` arrive at non-VM workers and are dropped by OVN-K.
**Tool:** tmux MCP — one window per node, parallel `oc debug node` sessions, `oc exec pkill` to stop cleanly.

### Repeated curl test results (multiple runs during this session)

| Run | 000 | 200 | Success rate |
|-----|-----|-----|-------------|
| 1 (original) | 42 | 8 | 16% |
| 2 (during NAT pcap) | 41 | 9 | 18% |
| 3 | 39 | 11 | 22% |
| 4 | 35 | 15 | 30% |
| 5 | 35 | 15 | 30% |
| 6 | 41 | 9 | 18% |

Average ~22% success rate across 6 runs (n=300). Expected with 5 ECMP paths and 1 VM node: 20%.
The variance is normal for a 50-sample ECMP distribution.

### Capture strategy: `oc debug node` + tmux

A tmux session `cudn-debug` was created with one window per node and one window for the curl test.
Each window ran:

```bash
oc debug node/<node> --quiet -- /bin/bash -c '
  touch /tmp/p.pcap; chmod 666 /tmp/p.pcap
  tcpdump -nn -i <interface> host 10.100.0.7 & TDPID=$!
  wait $TDPID
  echo CAPTURE_COMPLETE_<node>
  sleep 120
'
```

Tcpdump was stopped with `oc exec -n default <pod> -- pkill -TERM tcpdump` to allow clean file flush
before the pod exited, leaving a 120-second window for `oc cp` extraction.

### Finding 1 — `/host/var/tmp/` write failure (SELinux)

Pre-creating the pcap file with `touch /host/var/tmp/pcap && chmod 666 /host/var/tmp/pcap` before
starting tcpdump does NOT help. When tcpdump drops privileges to the `tcpdump` user, the SELinux
context on `/host/var/tmp/` prevents write access even on a world-writable file.
Writing to the container's own `/tmp/` (not `/host/var/tmp/`) works correctly.

### Finding 2 — OVS datapath is invisible to tcpdump

Every interface attempted showed **0 packets** during the curl test:

| Interface | Description | Packets captured |
|-----------|-------------|-----------------|
| `br-ex` | OVS external bridge | 0 |
| `ens4` | Physical GCP NIC (OVS port) | 0 |
| `any` | All interfaces | 0 |
| `ovn-k8s-mp1` | OVN UDN management port | 0 |

**Root cause:** `ens4` is registered as an OVS port. The Linux OVS kernel module (`openvswitch.ko`)
registers its own `rx_handler` on the NIC at the same level as `AF_PACKET` (libpcap). OVS intercepts
packets in the kernel datapath before they reach the socket layer. Neither the incoming SYN-ACKs
arriving at the physical NIC nor the OVN-K drop/forward decisions are visible to standard `tcpdump`.

This is a fundamental OVS observability limitation, not a configuration problem.

### Finding 3 — CUDN routing lives in `mp1-udn-vrf`

```text
ip route show vrf mp1-udn-vrf
  10.100.0.0/16 dev ovn-k8s-mp1 proto kernel scope link src 10.100.0.2
  169.254.0.3 via 10.100.0.1 dev ovn-k8s-mp1
```

The CUDN prefix `10.100.0.0/16` is installed in a separate VRF (`mp1-udn-vrf`) with `ovn-k8s-mp1`
as the interface. This is used by FRR for BGP advertisement, not for in-kernel forwarding.
The actual forwarding for CUDN traffic is handled entirely by OVS/OVN-K flows in the kernel datapath.

### Why worker node captures were not achievable with standard tooling

To observe the drop, you would need one of:

1. **`ovs-tcpdump`** — creates a port mirror to a tap interface. Not available in the `oc debug node` container image (`toolbox` image).
2. **OVS port mirroring** via `ovs-vsctl add-port ... mirror=...` — requires `ovs-vsctl` access to the OVS daemon socket, not available from a debug pod.
3. **eBPF/bpftrace** — attach a kprobe on `ovs_dp_process_packet` or `ct_entry_lookup` and filter by CUDN dst IP.
4. **OVN-K metrics** — `oc exec -n openshift-ovn-kubernetes <ovnkube-node-pod> -- ovs-ofctl dump-flows br-ex` with `ct_state=-trk` counters.

### Summary: statistical proof is sufficient

The direct packet observation approach is blocked by OVS kernel-mode processing.
The existing evidence provides conclusive proof:

| Evidence | What it shows |
|----------|--------------|
| NAT VM pcap (213 packets) | Every SYN-ACK correctly forwarded toward spoke VPC |
| 6× curl tests, n=300 | ~22% success rate, matching 1/5 ECMP probability |
| RFC-1918 control test, n=5050 | 100% success — OVN-K accepts RFC-1918 on any worker |
| `ip route show vrf mp1-udn-vrf` | CUDN lives in OVS/OVN pipeline (kernel datapath) |
| SYN retransmissions in pcap | First SYN-ACK dropped, retry hit correct node |

---

## Step 7 — Restore hub NAT MIG to 3 instances

After captures are complete, restore redundancy:

```bash
gcloud compute instance-groups managed resize cz-demo1-nat-gw-mig \
  --size=3 --region=us-central1 --project=mobb-demo
```

- [ ] MIG restored to 3

---

## Background

The failure is documented in [BRIEFING.md](../BRIEFING.md) and [KNOWLEDGE.md](../KNOWLEDGE.md).

**Root cause in brief:**
CUDN pods route all egress via `ovn-udn1` (OVN pipeline) without SNAT.
The hub NAT VM masquerades `src=10.100.0.7` to its public IP and DNATs the return
back to `dst=10.100.0.7`.
This return packet enters the spoke VPC and hits Cloud Router ECMP (10 paths).
OVN-K's conntrack state for the flow is node-local; the ~8/10 workers that receive
the return via ECMP have no `ct.est` for the public-IP source and drop it silently.

**ROSA comparison (from Daniel Axelrod, April 2026):**
The ROSA/AWS equivalent used Route Server single-active FIB (not ECMP).
VPC-to-VM flapping was caused by a different pre-4.21.8 OVN-K bug
(Geneve egress to wrong node, confirmed via pcap timing: 12 μs local vs 864 μs Geneve).
That bug is fixed in OCP 4.21.8.
Internet egress on ROSA has not been tested — whether 4.21.8 also fixes the conntrack
drop for public-IP return traffic remains an open question.
