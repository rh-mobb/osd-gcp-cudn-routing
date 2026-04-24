# Agent Prompt — ROSA CUDN Internet Egress Debugging

> Copy this entire document into a new Cursor agent window opened against the
> `osd-gcp-cudn-routing` workspace. The agent has access to `oc`, `aws`, `kubectl`,
> and all MCP tools available in this workspace.

---

## Objective

Reproduce the GCP CUDN internet egress debugging session — but on the ROSA/AWS cluster
deployed by `references/rosa-bgp/` — to answer one open question:

> **Does ROSA CUDN internet egress fail for the same reason as GCP?**
> Specifically: does the OVN-K conntrack node-locality problem cause ~1/N success rate
> on AWS, where N = number of BGP router nodes?

The GCP session produced definitive evidence (pcaps, curl stats, Wireshark analysis).
This session should produce equivalent evidence on ROSA so the two architectures can
be compared and the findings documented.

---

## Context you must read before starting

Read these files in the workspace. They contain everything needed to understand the
problem, the GCP findings, and what to look for on ROSA:

1. **`BRIEFING.md`** — root cause, 5-step failure chain, architecture comparison table
2. **`KNOWLEDGE.md`** — verified facts, especially the entries under:
   - "CUDN internet egress is fundamentally ECMP-unreliable…"
   - "The ECMP + OVN-K conntrack failure is specific to internet-sourced return IPs…"
3. **`docs/debug-internet-egress-2026-04-23.md`** — the full GCP debug session:
   every step, result, and finding. This is the template for what to reproduce on ROSA.
4. **`references/pcap-2026-04-23/README.md`** — what the GCP pcaps showed
5. **`references/rosa-bgp/README.md`** and **`references/rosa-bgp/CLAUDE.md`** —
   the ROSA reference architecture, Terraform layout, and key commands
6. **`references/rosa-pcap/Apr 9 all nodes/README`** and
   **`references/rosa-pcap/Apr 10 router on all nodes/README.txt`** — Daniel Axelrod's
   prior ROSA captures showing the inbound "flapping" problem (a different, pre-4.21.8
   OVN-K bug). These are context only — the flapping issue was inbound (EC2→VM), not
   internet egress (VM→internet).

---

## Architecture differences: ROSA vs GCP

Understand these before touching anything — the test protocol differs significantly.

| Dimension | GCP (done) | ROSA (this session) |
|-----------|-----------|---------------------|
| **Routing** | Cloud Router ECMP — 5 workers × 2 peers = 10 equal-cost paths | AWS VPC Route Server — single-active FIB: only **1 of N** workers is the next-hop in subnet route tables at a time |
| **ECMP semantics** | Every flow distributed across all 10 paths (~20% hit rate) | All flows go to 1 active router node (100% or 0% depending on which node is active) |
| **NAT path** | Linux MASQUERADE on hub NAT VMs in separate hub VPC | AWS NAT Gateway (managed) in same VPC — no NIC-registration constraint, so `src=10.100.x.x` is not dropped by AWS NAT |
| **Return packet flow** | Internet → hub NAT VM DNAT → spoke VPC → Cloud Router ECMP → random worker | Internet → AWS NAT GW DNAT → VPC → Route Server subnet route → **active BGP node** |
| **Router nodes** | All 5 workers (baremetal + standard), `bgp_router=true` | 3 dedicated `c5.metal` baremetal nodes (1 per AZ), `bgp_router=true` label, src/dst checks disabled on ENI |
| **BGP peering** | Per-node FRRConfiguration CRs, each node peers with Cloud Router 2 interfaces | Single `FRRConfiguration` CR (`all-nodes`), each router node peers with 6 Route Server endpoints (2 per AZ) |
| **Internet egress NAT** | Linux `MASQUERADE` on hub NAT VMs | AWS NAT Gateway — automatically handles `src=10.100.x.x` if the packet reaches it |
| **No hub VPC** | Separate hub VPC with ILB + NAT MIG | No hub VPC — NAT Gateway is in the same VPC as ROSA |
| **OVN-K version** | OCP 4.21 (check exact patch) | Check `oc version` — if <4.21.8, a separate Geneve egress bug also exists |
| **SSH to VMs** | `scripts/virt-ssh.sh` via `netshoot-cudn` jump pod | `virtctl ssh` may work on ROSA if not using primary UDN, or use `oc rsh` into a pod in `cudn1` namespace as a jump |
| **Capture target** | Hub NAT VM `gif0` (IAP SSH + tcpdump) | EC2 test instance (plain SSH + tcpdump on `eth0`) or the active BGP router node |

### Critical implication of Route Server single-active

On GCP: return traffic hits a random worker, so ~20% of flows succeed.

On ROSA: return traffic goes to **one specific worker** (the one currently active in the
Route Server FIB). If that worker is the VM's node → **100% success**. If it is not
→ **100% failure**. The expected long-run average is `1/N` where N = number of router
nodes = 3 in the reference deployment.

This means internet egress on ROSA is expected to be **either 100% or 0%** at any
instant, not the ~20% probabilistic pattern seen on GCP. The failure flips when
Route Server failover moves the active next-hop to a different node.

---

## Pre-flight: understand the cluster state

Before running any tests, gather the following. Document everything in the debug doc
you will create (see Documentation section below).

```bash
# 1. ROSA cluster access (run from references/rosa-bgp/ if using its Terraform outputs)
oc login $(cd references/rosa-bgp && terraform output -raw rosa_api_url) \
  -u cluster-admin \
  -p $(cd references/rosa-bgp && terraform output -raw rosa_cluster_admin_password)

# 2. OCP version — critical: check if >= 4.21.8 (pre-4.21.8 has a separate Geneve bug)
oc version

# 3. All worker nodes and their roles
oc get nodes -o wide
oc get nodes -l bgp_router=true -o wide   # router nodes only

# 4. CUDN VMs — get IPs and which nodes they are scheduled on
oc get vmi -n cudn1 -o wide

# 5. BGP configuration
oc get frrconfiguration -n openshift-frr-k8s -o yaml
oc get routeadvertisements -A -o yaml

# 6. Check AWS subnet route tables — which node is active BGP next-hop for 10.100.0.0/16
#    Replace ROUTE_TABLE_ID with your VPC's private route table IDs
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=*private*" \
  --query "RouteTables[*].{TableId:RouteTableId,Routes:Routes[?DestinationCidrBlock=='10.100.0.0/16']}" \
  --output table
# This shows the ENI/instance that is currently the active next-hop.

# 7. Identify the EC2 test instance (if deployed via test-instance.tf)
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*test-instance*" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{Name:Tags[?Key=='Name']|[0].Value,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}" \
  --output table

# 8. Verify CUDN namespace and netshoot jump pod availability
oc get pods -n cudn1
```

Note down:
- CUDN VM name, IP, and which **worker node** it is scheduled on
- Which worker node is currently the **active BGP next-hop** in the Route Server FIB
- Whether the VM's node == the active BGP node (determines expected internet egress result)
- IP of the EC2 test instance for the control test
- OCP version

---

## Test protocol

Create `docs/debug-internet-egress-rosa-<YYYY-MM-DD>.md` and document every step,
command, and result as you go, modelled on `docs/debug-internet-egress-2026-04-23.md`.

### Step 1 — Baseline internet egress failure rate

Run 50 `curl` requests from the CUDN VM to a public endpoint.

**SSH into the CUDN VM.** Try `virtctl ssh` first:
```bash
# From cluster directory:
virtctl ssh fedora@test-vm-cudn -n cudn1
```

If `virtctl ssh` fails (known limitation for primary UDN — see KNOWLEDGE.md), use a
jump pod in `cudn1`:
```bash
# Get a shell on a pod in cudn1 that can reach the VM
POD=$(oc get pods -n cudn1 -o jsonpath='{.items[0].metadata.name}')
oc exec -n cudn1 $POD -- ssh -o StrictHostKeyChecking=no fedora@<VM_IP>
```

Alternatively, use `oc debug node/<vm-node>` to exec a script via `nsenter`.

Once inside the VM, run:
```bash
for i in $(seq 1 50); do
  curl -4s --max-time 3 -o /dev/null -w "%{http_code}\n" https://ifconfig.me
done | sort | uniq -c
```

**Expected result (if VM's node ≠ active BGP node):** `50 000` — 100% failure.
**Expected result (if VM's node == active BGP node):** `50 200` — 100% success.

Record exact counts. Repeat 2–3 times to detect any flapping.

### Step 2 — Control test: RFC-1918 return source (EC2 test instance)

Run the same test to the EC2 test instance IP (RFC-1918 source on return):
```bash
for i in $(seq 1 50); do
  curl -4s --max-time 3 -o /dev/null -w "%{http_code}\n" http://<EC2_PRIVATE_IP>:<PORT>/
done | sort | uniq -c
```

The EC2 instance has `httpd` / python HTTP server running (see `test-instance.tf`).
If port unknown, check: `aws ec2 describe-instances ... | grep -i http` or try port 80.

**Expected:** `50 200` — 100% success regardless of which node is active, because
return `src=10.0.x.x` is RFC-1918 and OVN-K Geneve-forwards to the correct node.

Scale up to 500 and 5 000 requests to confirm the control result.

### Step 3 — Packet capture on EC2 test instance (control test)

SSH into the EC2 test instance (it should have a public IP or be reachable via SSM):
```bash
# Via AWS SSM if no public IP:
aws ssm start-session --target <INSTANCE_ID>

# Or direct SSH if public IP available:
ssh -i <key> ec2-user@<PUBLIC_IP>
```

While the CUDN VM curl test runs, capture on `eth0`:
```bash
sudo tcpdump -nn -i eth0 host <CUDN_VM_IP> -w /tmp/rosa-ec2-control-$(date +%Y%m%d-%H%M%S).pcap
```

Stop with `Ctrl-C` after the curl test completes. Copy the pcap to
`references/pcap-rosa-<date>/`. This will show the full TCP handshake for every
request — confirming 100% success and providing a clean baseline.

### Step 4 — Internet egress capture (EC2 perspective on the public side)

This is the ROSA equivalent of the GCP NAT VM capture. Since AWS NAT Gateway is not
directly inspectable, the closest equivalent is:

**Option A: Capture on the active BGP router node**

```bash
oc debug node/<active-bgp-node> --quiet -- /bin/bash -c '
  touch /tmp/egress.pcap; chmod 666 /tmp/egress.pcap
  tcpdump -nn -i any dst host <CUDN_VM_IP> -w /tmp/egress.pcap &
  TDPID=$!
  wait $TDPID
  sleep 60
'
```

Stop the capture after the curl test with:
```bash
POD=$(oc get pods -n default -o name | grep debug | head -1)
oc exec $POD -- pkill -TERM tcpdump
sleep 10
oc cp $POD:/tmp/egress.pcap references/pcap-rosa-<date>/router-node-egress.pcap
```

**Note:** Expect 0 packets due to OVS datapath invisibility (same as GCP — see
`docs/debug-internet-egress-2026-04-23.md` Step 5 for the full explanation).
Document this finding if confirmed.

**Option B: Use VPC Flow Logs** (AWS-specific, no OVS limitation)

If VPC Flow Logs are enabled on the ROSA VPC:
```bash
# Find the ENI of the active BGP router node
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=<ROUTER_NODE_IP>" \
  --query "Reservations[*].Instances[*].InstanceId" --output text)
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query "Reservations[*].Instances[*].NetworkInterfaces[*].NetworkInterfaceId"

# Then query CloudWatch Logs for that ENI
# This can show rejected packets (action=REJECT) that would be OVN-K drops
```

**Option C: VPC Traffic Mirroring** (most direct, but requires setup)

VPC Traffic Mirroring can mirror the router node's ENI to an inspection instance.
This bypasses OVS entirely as it mirrors at the hypervisor level. Only set up if
you want direct packet-level evidence. Describe the setup in the debug doc.

### Step 5 — Route Server failover test

This is unique to ROSA and has no GCP equivalent. It validates that the success/failure
pattern flips when the active BGP node changes.

1. Note the current active BGP node and whether internet egress is succeeding (100%)
   or failing (0%) for the VM.

2. Force a failover by draining the active router node:
   ```bash
   ACTIVE_NODE=<the-current-active-bgp-node>
   oc adm cordon $ACTIVE_NODE
   oc adm drain $ACTIVE_NODE --ignore-daemonsets --delete-emptydir-data
   ```

3. Wait for Route Server to update the subnet route tables to the next router node
   (typically within 30-60 s, driven by BGP keepalive timer).

4. Check which node is now active:
   ```bash
   aws ec2 describe-route-tables \
     --filters "Name=tag:Name,Values=*private*" \
     --query "RouteTables[*].Routes[?DestinationCidrBlock=='10.100.0.0/16']"
   ```

5. Rerun the 50-curl internet egress test. Document whether the result changed.

6. **Restore the node:**
   ```bash
   oc adm uncordon $ACTIVE_NODE
   ```

This step definitively proves whether internet egress success is determined by which
node is active in Route Server — confirming the same root cause as GCP (OVN-K
conntrack node-locality) but with different failure statistics (0% or 100% vs ~20%).

### Step 6 — Worker node capture attempts (for completeness)

Run the same worker node capture attempts as GCP Step 5 to confirm OVS invisibility
on AWS. Pick 2-3 workers — the active BGP router node, a non-router node, and the
VM's node:

```bash
oc debug node/<node> --quiet -- /bin/bash -c '
  touch /tmp/p.pcap; chmod 666 /tmp/p.pcap
  tcpdump -nn -i any host <CUDN_VM_IP> -w /tmp/p.pcap &
  TDPID=$!
  wait $TDPID
  sleep 60
'
```

Stop with `oc exec ... -- pkill -TERM tcpdump`. Copy and inspect.

Document which interfaces were tried, packet counts, and whether the OVS
invisibility finding holds on AWS (expected: yes — same OVS kernel module).

Also confirm the VRF routing on AWS workers:
```bash
oc debug node/<bgp-router-node> --quiet -- chroot /host ip route show vrf mp1-udn-vrf
```

Expected: `10.100.0.0/16 dev ovn-k8s-mp1 proto kernel scope link src 10.100.0.2`
(same as GCP — CUDN lives in `mp1-udn-vrf`).

---

## Documentation requirements

### 1. Debug session doc

Create `docs/debug-internet-egress-rosa-<YYYY-MM-DD>.md` modelled exactly on
`docs/debug-internet-egress-2026-04-23.md`. Include:
- Environment table (cluster name, region, nodes, BGP roles, VM IPs)
- Which node is the VM on vs which is active BGP next-hop
- Results of every test step with exact counts
- Pcap locations and what they show
- Route Server failover results
- OVS observability finding
- Comparison with GCP findings

### 2. Pcap directory

Save all captures to `references/pcap-rosa-<date>/` with a `README.md` describing
each file (what interface, what filter, what test was running).

### 3. Update KNOWLEDGE.md

Add a new entry or update the existing ROSA-specific section with:
- Whether internet egress fails on ROSA and at what rate
- Whether the failure mode is 0%/100% (as expected from single-active) vs probabilistic
- Whether OVS observability limitation holds on AWS
- Whether Route Server failover changes the internet egress result
- OCP version tested and whether any Geneve bug (pre-4.21.8) was also observed
- Confidence score and what would falsify each finding

### 4. Canvases / HTML

If the ROSA findings differ meaningfully from GCP (e.g., 0%/100% vs 20% failure pattern),
create a new canvas at:
- `cudn-rosa-internet-egress.canvas.tsx`
- `docs/cudn-rosa-internet-egress.html`

Model them on the existing `cudn-ecmp-drop-flow.canvas.tsx` and
`docs/cudn-ecmp-drop-flow.html` but show the Route Server single-active architecture
instead of Cloud Router ECMP. The key visual difference: instead of 10 equal-cost
paths fanning out from a Cloud Router, show a single active path with a "standby" group.

---

## Key technical reference

### Connecting to the CUDN VM on ROSA

The ROSA VM (`test-vm-cudn` in `cudn1`) uses `bridge: {}` binding and a Fedora cloud
image. Password is `fedora` (from cloud-init in `test-vm-cudn.yaml`).

Try in order:
```bash
# 1. virtctl ssh (may work on ROSA unlike GCP primary UDN — test it)
virtctl ssh fedora@test-vm-cudn -n cudn1

# 2. Via a pod in cudn1 as a jump
oc run -n cudn1 jump --image=nicolaka/netshoot --restart=Never -- sleep 3600
oc exec -n cudn1 jump -- ssh -o StrictHostKeyChecking=no fedora@<VM_IP>

# 3. Via oc debug node on the VM's node + nsenter into the VM's network namespace
```

### Key ROSA AWS CLI commands

```bash
# Get VPC ID (from terraform outputs or describe)
VPC_ID=$(cd references/rosa-bgp && terraform output -raw vpc1_id 2>/dev/null)

# List route tables with CUDN route
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[*].{TableId:RouteTableId,Name:Tags[?Key=='Name']|[0].Value,CUDNRoute:Routes[?DestinationCidrBlock=='10.100.0.0/16']}"

# Check BGP peer status for all Route Server peers
RS_ID=$(cd references/rosa-bgp && terraform output -raw vpc1_route_server_id 2>/dev/null)
aws ec2 describe-route-server-peers --route-server-id $RS_ID \
  --query "RouteServerPeers[*].{PeerId:RouteServerPeerId,BGPState:BgpOptions.PeerBgpState,NodeIP:PeerAddress}"

# List router nodes by tag
aws ec2 describe-instances \
  --filters "Name=tag:bgp_router,Values=true" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{Name:Tags[?Key=='Name']|[0].Value,PrivateIP:PrivateIpAddress,InstanceId:InstanceId,AZ:Placement.AvailabilityZone}"
```

### Known issues and caveats

1. **OVS invisibility:** Same as GCP — `ens5` (or equivalent AWS NIC) is an OVS port.
   Standard tcpdump in `oc debug node` shows 0 packets for CUDN traffic.
   Write pcap to `/tmp/` in container (not `/host/var/tmp/`) to avoid SELinux denial.

2. **OCP version:** If the cluster is running <4.21.8, there is also a separate
   Geneve egress bug (pre-4.21.8) that causes egress traffic to be tunneled to the
   wrong node's gateway. This would show as a different failure pattern — check
   `oc version` first. The conntrack problem tested here is separate and expected
   in all versions.

3. **Route Server single-active:** The FIB installs only one next-hop per prefix.
   All 3 router nodes have BGP sessions in the RIB, but only one is in FIB.
   Unlike GCP's ECMP, this means internet egress is binary (all-or-nothing) based
   on which node is active.

4. **ENI src/dst checks:** Must be disabled on all router nodes. Check:
   ```bash
   for INSTANCE_ID in $(aws ec2 describe-instances \
     --filters "Name=tag:bgp_router,Values=true" \
     --query "Reservations[*].Instances[*].InstanceId" --output text); do
     aws ec2 describe-instance-attribute \
       --instance-id $INSTANCE_ID --attribute sourceDestCheck \
       --query "{InstanceId:InstanceId,SourceDestCheck:SourceDestCheck.Value}"
   done
   ```
   Must be `false` on all. If any are `true`, re-run the DaemonSet or manually disable.

5. **Internet egress path on ROSA:** AWS NAT Gateway handles `src=10.100.0.x` correctly
   (unlike GCP Cloud NAT which drops non-registered IPs). The DNAT on return rewrites
   `dst` back to `10.100.0.x`. That return packet then routes via the VPC subnet route
   table → active BGP router node. The OVN-K conntrack check happens there.

6. **Terraform state:** If the Terraform state in `references/rosa-bgp/` is stale or
   the cluster no longer exists, get cluster connection details from the Red Hat OCM
   console or from the person who deployed it (likely Daniel Axelrod / the ROSA team).

---

## Success criteria for this session

The session is complete when you have documented:

- [ ] The internet egress success rate from the CUDN VM (exact counts, ≥3 runs)
- [ ] Whether the failure pattern is 0%/100% (expected) or probabilistic
- [ ] Whether Route Server failover changes the internet egress result
- [ ] The RFC-1918 control test result (expected: 100% success, n≥500)
- [ ] Whether OVS observability limitation holds on AWS workers
- [ ] OCP version tested
- [ ] A completed `docs/debug-internet-egress-rosa-<date>.md`
- [ ] KNOWLEDGE.md updated with ROSA findings
- [ ] Any pcaps saved to `references/pcap-rosa-<date>/`

The core question to answer: **is the root cause the same as GCP (OVN-K conntrack
node-locality) expressed differently via Route Server single-active semantics, or is
there a different failure mechanism on ROSA?**
