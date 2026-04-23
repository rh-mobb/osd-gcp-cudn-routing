# Networking validation runbook (human execution)

This runbook is for **people** exercising the data plane after BGP/CUDN is configured. It is written around the findings in **[BRIEFING.md](../BRIEFING.md)**:

- **RFC-1918 / private paths** (intra-cluster, VPC, on-prem): OVN-K accepts return traffic on any worker and forwards correctly. These paths are the **product-quality bar**.
- **Public-internet paths**: return packets carry a **public source IP**. OVN-K only accepts them on the **originating worker**. With **ECMP** (multiple equal-cost next hops to the CUDN), return traffic often lands on the wrong node and is **dropped**. Success is **partial and statistical**, not a configuration mistake.

Do **not** conclude “routing is broken” because internet `curl` flakes. Do conclude “routing is broken” if **private** checks fail consistently.

**Companion automation:** [`scripts/networking-validation-test.sh`](../scripts/networking-validation-test.sh) (`make networking.validate`) covers a subset with scripted gates. This document goes wider (volume, both outcome classes, manual observation).

---

## 1. What you are proving

| Concern (BRIEFING) | How this runbook addresses it |
|--------------------|-------------------------------|
| CUDN ↔ VPC / RFC-1918 works | Repeated pod ↔ echo VM ping/curl; VM guest checks where applicable |
| CUDN → internet is ECMP-unreliable | High-attempt `curl`/ICMP samples; record **success fraction**, not pass/fail |
| `bridge` / `l2bridge` vs `masquerade` does **not** fix internet on primary UDN | Exercise **both** virt-e2e VMs; compare **private** reachability; expect **same class** of internet flakiness |
| Masquerade disrupts during migration | Full virt e2e or manual migration + concurrent ping |
| Do not use CUDN as stable internet egress | Sign-off separates **private OK** from **internet characterized** |

---

## 2. Preconditions

1. `oc login` to the cluster; `kubectl`/`oc` context correct.
2. Terraform stack directory available (default **`cluster_bgp_routing/`**). From that directory you can run `terraform output`.
3. Test workloads in the CUDN namespace(s) you care about (e.g. **`netshoot-cudn`**, **`icanhazip-cudn`**). From the **repo root**: `bash cluster_bgp_routing/scripts/deploy-cudn-test-pods.sh -n cudn1`, or run [`e2e-cudn-connectivity.sh`](../scripts/e2e-cudn-connectivity.sh) with **`-C cluster_bgp_routing`**.
4. Optional: KubeVirt virt-e2e VMs (see [§ 6](#6-kubevirt--both-bindings-stress)).
5. Optional: `gcloud` authenticated if you will SSH to the echo VM (IAP) for VM → pod tests.

**Tools:** `oc`, `curl`, `ping`; optional `mtr`, `virtctl`, `gcloud`, `terraform`, `jq`, repo **`Makefile`** targets **`virt.ssh.bridge`** / **`virt.ssh.masq`** (see §2.1).

**Paths (common mistake):** In this repository, the **Terraform root** is the **`cluster_bgp_routing/`** directory. Helper scripts **`cudn-pod-ip.sh`** and **`deploy-cudn-test-pods.sh`** live in **`cluster_bgp_routing/scripts/`**, not in the repo-level **`scripts/`** folder. If `bash: .../cudn-pod-ip.sh: No such file or directory`, you are either in the wrong directory or using the wrong path—set **`CLUSTER_DIR`** to the **absolute** path to **`cluster_bgp_routing`** and use **`"$CLUSTER_DIR/scripts/cudn-pod-ip.sh"`** below.

Set variables for copy-paste:

```bash
export NAMESPACE=cudn1

export CLUSTER_DIR="$PWD/cluster_bgp_routing"
export OSD_CUDN_REPO="$(cd "$CLUSTER_DIR/.." && pwd)"

export POD_IP_SH="$CLUSTER_DIR/scripts/cudn-pod-ip.sh"
test -f "$POD_IP_SH" || { echo "Missing $POD_IP_SH — fix CLUSTER_DIR"; exit 1; }

export ECHO_IP="$(cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_internal_ip | tr -d '\r\n')"
export ECHO_URL="$(cd "$CLUSTER_DIR" && terraform output -raw echo_client_http_url | tr -d '\r\n')"
export CLUSTER_NAME="$(cd "$CLUSTER_DIR" && terraform output -raw cluster_name | tr -d '\r\n')"
export GCP_PROJECT="$(cd "$CLUSTER_DIR" && terraform output -raw gcp_project_id | tr -d '\r\n')"
export VM_ZONE="$(cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_zone | tr -d '\r\n')"
```

Discover CUDN pod IPs:

```bash
export NETSHOOT_IP="$(bash "$POD_IP_SH" -n "$NAMESPACE" netshoot-cudn)"
export ICAN_POD_IP="$(bash "$POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn)"
```

Discover the interface name netshoot uses for the CUDN (for `ping -I`):

```bash
oc exec -n "$NAMESPACE" netshoot-cudn -- ip a
# Pick the interface that carries NETSHOOT_IP (often ovn-udn1); use the base name without @peer, e.g. ovn-udn1
export PING_IFACE=ovn-udn1   # override if your ip -br output differs
```

**Recording:** Keep a log (timestamped markdown or ticket). For internet stress, always record **attempts**, **successes**, and **worker node** (`oc get pod -n "$NAMESPACE" netshoot-cudn -o wide`).

### 2.1 SSH to virt-e2e guests via netshoot (preferred for CUDN)

**`virtctl ssh`** to the VMI is still unsupported on primary UDN, but normal **TCP SSH to the guest’s CUDN IP** works: virt-e2e cloud-init enables **`sshd`** and user **`cloud-user`**.

**Keys:** [`e2e-virt-live-migration.sh`](../scripts/e2e-virt-live-migration.sh) creates **`$CLUSTER_DIR/.virt-e2e/id_ed25519`** (private) and **`id_ed25519.pub`** before **`oc apply`**; the **public** line is in **`ssh_authorized_keys`** for **`cloud-user`**. [`virt-ssh.sh`](../scripts/virt-ssh.sh) **`oc cp`**’s the private key into **`netshoot-cudn`** each run (you do not need to do that by hand when using **`make`** / **`virt-ssh.sh`**).

**Primary workflow — interactive shell on the guest**

From the **repository root** (the directory that contains **`Makefile`** and **`cluster_bgp_routing/`** — use **`OSD_CUDN_REPO`** from §2):

```bash
cd "$OSD_CUDN_REPO"
export CUDN_NAMESPACE="${NAMESPACE:-cudn1}"   # optional if not cudn1

make virt.ssh.bridge    # l2bridge VM (default name virt-e2e-bridge)
# or
make virt.ssh.masq      # masquerade VM (default virt-e2e-masq)
```

Override VM names if you customized them: **`VIRT_E2E_VM_NAME_BRIDGE`**, **`VIRT_E2E_VM_NAME_MASQ`**. The script prints **`[virt-ssh] <vm> → cloud-user@<ip> …`** to stderr; use that IP when a step below needs the guest CUDN address.

All **§ 4.2** loops and **§ 6** guest **`ping` / `curl`** checks are meant to run **inside** the shell you get from **`make virt.ssh.bridge`** or **`make virt.ssh.masq`** (paste the commands there). For **masquerade** tests, open a **second** session with **`make virt.ssh.masq`**.

**One-shot / scripted remote command (from laptop, same path as `make`)**

[`virt-ssh.sh`](../scripts/virt-ssh.sh) accepts **`-- <command>…`** after the VM name (non-interactive **`ssh`**, **`BatchMode`**):

```bash
bash "$OSD_CUDN_REPO/scripts/virt-ssh.sh" -C "$CLUSTER_DIR" -n "$NAMESPACE" \
  "${VIRT_E2E_VM_NAME_BRIDGE:-virt-e2e-bridge}" -- ping -c 5 "${ECHO_IP}"

bash "$OSD_CUDN_REPO/scripts/virt-ssh.sh" -C "$CLUSTER_DIR" -n "$NAMESPACE" \
  "${VIRT_E2E_VM_NAME_BRIDGE:-virt-e2e-bridge}" -- \
  curl -sS --connect-timeout 10 --max-time 25 "${ECHO_URL}"
```

Quote the URL if it contains **`&`**. Swap in **`${VIRT_E2E_VM_NAME_MASQ:-virt-e2e-masq}`** for the masquerade VM.

**If the guest accepts TCP but rejects your key** (`Permission denied (publickey)`):

1. **Stale key / first-boot only:** Cloud-init normally writes **`~cloud-user/.ssh/authorized_keys` once** from the **first** userdata the VM saw. If you **regenerated** **`id_ed25519`** after the VM already booted, or applied a VM that was created with an older key, the disk still has the **old** pubkey. **Check:** on the guest (serial console, or SSH if you can still log in), **`cat /home/cloud-user/.ssh/authorized_keys`**. On your laptop: **`ssh-keygen -y -f "$CLUSTER_DIR/.virt-e2e/id_ed25519"`** — that single line must appear in **`authorized_keys`**. If not, either **delete the VM** (and PVC if you need a truly fresh disk) and re-run **`e2e-virt-live-migration.sh`**, or **append** the current **`.pub`** line to **`authorized_keys`** via console.
2. **Wrong key file:** Confirm troubleshooting uses **`id_ed25519`** (private), not **`.pub`**.
3. **Password auth:** Cloud-init sets **`ssh_pwauth: true`** and **`$CLUSTER_DIR/.virt-e2e/console-password`**. Resolve **`GUEST_IP`** (stderr line from **`virt-ssh.sh`**, or **`oc get vmi <name> -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}'`**), then from netshoot (interactive):  
   **`oc exec -it -n "$NAMESPACE" netshoot-cudn -c netshoot -- ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no "cloud-user@${GUEST_IP}"`**  
   and paste the password from **`cat "$CLUSTER_DIR/.virt-e2e/console-password"`**.

**`netshoot-cudn`** is on the same CUDN and can reach the guest IP on port 22.

**Manual equivalent (debug only)** — same steps **`virt-ssh.sh`** performs: copy **`id_ed25519`** to **`/tmp/virt-e2e-vm-key`**, **`chmod 600`**, **`oc exec … ssh -i /tmp/virt-e2e-vm-key … cloud-user@<ip>`**. Repeat the copy if **netshoot** is recreated.

### 2.2 SSH via echo VM (jump host, optional)

Use this if you prefer not to copy the key into netshoot, or for cross-checks. The echo instance must have an **`ssh`** client and a **layer-3 route** to the CUDN prefix (typical on this stack: VPC + advertised **`10.100.0.0/16`** or your **`cudn_cidr`**).

Copy the private key to the echo VM (IAP):

```bash
gcloud compute scp "$CLUSTER_DIR/.virt-e2e/id_ed25519" \
  "${CLUSTER_NAME}-echo-client:~/virt-e2e-vm-key" \
  --project="$GCP_PROJECT" --zone="$VM_ZONE" --tunnel-through-iap
gcloud compute ssh "${CLUSTER_NAME}-echo-client" \
  --project="$GCP_PROJECT" --zone="$VM_ZONE" --tunnel-through-iap \
  --command="chmod 600 ~/virt-e2e-vm-key"
```

Then SSH to the echo VM and hop to the guest (guest CUDN IP: stderr line from **`virt-ssh.sh`** / **`make virt.ssh.bridge`**, or **`oc get vmi`** — see **§ 2.1**):

```bash
gcloud compute ssh "${CLUSTER_NAME}-echo-client" \
  --project="$GCP_PROJECT" --zone="$VM_ZONE" --tunnel-through-iap
# on echo VM:
# ssh -i ~/virt-e2e-vm-key -o StrictHostKeyChecking=no cloud-user@VM_BRIDGE_IP
```

If **`ssh: command not found`** on the echo image, use **§ 2.1** or install **`openssh-clients`** (image-dependent).

---

## 3. Track A — Known-good paths (stress)

These should be **stable** under load appropriate for a lab. If they fail, fix routing/firewall/NCC/BGP before interpreting internet results.

### 3.1 Intra-namespace pod → pod (CUDN)

From `netshoot`, ping the `icanhazip-cudn` pod IP on the CUDN interface:

```bash
oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 20 "$ICAN_POD_IP"
```

**Expect:** 0% loss.

### 3.2 Pod → VPC echo VM (egress with RFC-1918 return)

Light check:

```bash
oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 5 "$ECHO_IP"
oc exec -n "$NAMESPACE" netshoot-cudn -- curl -sS --connect-timeout 10 --max-time 25 "$ECHO_URL"
```

**Expect:** ping succeeds (unless ICMP blocked; then rely on HTTP). HTTP body should equal **`NETSHOOT_IP`** (echo service reflects caller).

**Stress:** run many sequential curls and require **100%** success on the private check (example: 50 iterations):

```bash
ok=0; fail=0; i=0
while [ "$i" -lt 50 ]; do
  i=$((i + 1))
  body="$(oc exec -n "$NAMESPACE" netshoot-cudn -- curl -sS --connect-timeout 10 --max-time 25 "$ECHO_URL" 2>/dev/null)" || { fail=$((fail+1)); continue; }
  if [ "$body" = "$NETSHOOT_IP" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done
echo "pod→echo HTTP ok=$ok fail=$fail (expect fail=0)"
```

### 3.3 Echo VM → CUDN pod (inbound from VPC)

Same checks as [`e2e-cudn-connectivity.sh`](../scripts/e2e-cudn-connectivity.sh) step **3/3**: from the echo VM, reach **`icanhazip-cudn`** by **pod IP**; HTTP on **8080** returns the caller IP as the pod sees it (must equal **`ECHO_IP`** — Terraform **`echo_client_vm_internal_ip`**).

**Needs:** `gcloud` authenticated; variables **`CLUSTER_NAME`**, **`GCP_PROJECT`**, **`VM_ZONE`**, **`ICAN_POD_IP`**, **`ECHO_IP`** from §2. Instance name is **`${CLUSTER_NAME}-echo-client`**. SSH uses **IAP** (GCP firewall must allow **35.235.240.0/20** to the VM, as in the reference stack).

Quick check (single ping + one curl; compare body to `ECHO_IP`):

```bash
gcloud compute ssh "${CLUSTER_NAME}-echo-client" \
  --project="$GCP_PROJECT" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  --command="set -euo pipefail; ping -c 3 '${ICAN_POD_IP}'; body=\$(curl -sS --connect-timeout 10 --max-time 25 'http://${ICAN_POD_IP}:8080/'); echo \"body='\$body' expected='${ECHO_IP}'\"; test \"\$body\" = '${ECHO_IP}'"
```

Interactive shell on the echo VM (then run `ping` / `curl` by hand):

```bash
gcloud compute ssh "${CLUSTER_NAME}-echo-client" \
  --project="$GCP_PROJECT" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap
# on the VM:
# ping -c 3 "$ICAN_POD_IP"    # paste IP
# curl -sS "http://$ICAN_POD_IP:8080/"   # should print the echo VM IP (same as ECHO_IP)
```

**Expect:** ping succeeds (unless ICMP blocked). HTTP body **exactly** **`ECHO_IP`**. If the body differs or is empty, the VPC → CUDN path or the `icanhazip-cudn` pod is wrong—not an internet/ECMP issue.

### 3.4 Second CUDN namespace (if deployed)

Repeat §§ 3.1–3.2 with `NAMESPACE=cudn2` (and fresh `NETSHOOT_IP` / `ICAN_POD_IP`). Cross-namespace tests are **out of scope** unless you have a defined design for UDN ↔ UDN.

### 3.5 Track A sign-off

- [ ] Pod → pod on CUDN: stable under your stress counts.
- [ ] Pod → echo VM: HTTP reflection correct on **every** attempt in your private stress loop.
- [ ] Echo VM → pod: matches expectations for your topology.
- [ ] If virt-e2e is deployed: **§ 6** step 2 — from **`make virt.ssh.bridge`** / **`virt-ssh.sh`** (guest): echo VM **`ping`** + **`curl`**; HTTP body equals bridge guest CUDN IP (optional: **`make virt.ssh.masq`** for masq VM).
- [ ] Optional second namespace: same.

If any item fails, **stop** and treat as a routing or firewall defect—not “internet noise.”

---

## 4. Track B — Known-bad / statistical paths (internet stress)

Per **BRIEFING.md**, traffic to the **public internet** gets return packets with **public source IPs**. ECMP then delivers those returns to a **random** worker; OVN-K drops them unless they hit the **originating** worker. You are measuring **probability**, not chasing 100% success.

### 4.1 From CUDN pod (netshoot)

Run a large sample of TCP connects (example: 100):

```bash
URL="${NETVAL_INTERNET_URL:-https://icanhazip.com}"
ok=0; fail=0; n=100; i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  if oc exec -n "$NAMESPACE" netshoot-cudn -- timeout 25 curl -4 -fsS \
    --connect-timeout 10 --max-time 20 "$URL" -o /dev/null 2>/dev/null; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
  fi
done
echo "internet curl sample: ok=$ok fail=$fail of $n (expect variable ok; see BRIEFING)"
```

Optional: **`mtr`** or repeated **`ping -c 50 8.8.8.8`** from netshoot (ICMP may still show loss patterns; interpret alongside TCP).

**Interpretation:** document **ok/n**. Compare to BRIEFING’s ~10–20% success band for GCP hub/spoke only as a sanity check—your cluster may differ. **Do not** fail Track A because Track B is low.

### 4.2 From KubeVirt guests (both bindings)

Run only **after** virt-e2e VMs exist (**§ 6**). Default VM names: **`virt-e2e-bridge`** (l2bridge) and **`virt-e2e-masq`** (masquerade).

**Workflow:** use **§ 2.1** — from **`cd "$OSD_CUDN_REPO"`**, run **`make virt.ssh.bridge`**, paste **A)** or **B)** below at the guest prompt, exit, then **`make virt.ssh.masq`** and repeat so you have samples from **both** bindings. Optional jump host for cross-checks: **§ 2.2** (echo VM).

**`virtctl ssh`** to the VMI API is still **not** supported on primary UDN.

**Last resort — serial / web console:** if you cannot use **§ 2.1** (key mismatch, netshoot missing), use **`virtctl console`** or the web UI (**Virtualization → VirtualMachines → VM → Console**). **`virtctl console` does not accept a password on the CLI**—type **`cloud-user`** and the password at the prompt.

```bash
export VM_BRIDGE="${VIRT_E2E_VM_NAME_BRIDGE:-virt-e2e-bridge}"
export VM_MASQ="${VIRT_E2E_VM_NAME_MASQ:-virt-e2e-masq}"
export VIRT_CONSOLE_PW="$CLUSTER_DIR/.virt-e2e/console-password"

echo "Console login (both virt-e2e VMs use the same cloud-init user/password):"
echo "  Username: cloud-user"
echo "  Password file: $VIRT_CONSOLE_PW"
echo -n "  Password: "; cat "$VIRT_CONSOLE_PW"; echo

echo "Attach to bridge VM (disconnect: usually Ctrl+] then quit, or see virtctl console -h):"
echo "  virtctl console ${VM_BRIDGE} -n ${NAMESPACE}"
echo "Attach to masquerade VM:"
echo "  virtctl console ${VM_MASQ} -n ${NAMESPACE}"
echo "# If you get 404, try: virtctl console vmi/${VM_BRIDGE} -n ${NAMESPACE} (virtctl/KubeVirt version dependent; see ARCHITECTURE.md)"
```

**A) Inside the guest** (shell from **`make virt.ssh.bridge`** / **`make virt.ssh.masq`**, or console session above) — public HTTPS (same idea as **§ 4.1**):

```bash
URL="${NETVAL_INTERNET_URL:-https://icanhazip.com}"
ok=0; fail=0; n=50; i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  if timeout 25 curl -4 -fsS --connect-timeout 10 --max-time 20 "$URL" -o /dev/null 2>/dev/null; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done
echo "guest internet curl: ok=$ok fail=$fail of $n (repeat on second VM; compare fractions)"
```

**B) Inside the guest** — in-VM **icanhazip-clone** (virt-e2e cloud-init, **host-network** podman; still reflects egress behavior). Run in the same guest session as **A)** (same **`make virt.ssh.…`** window or console):

```bash
ok=0; fail=0; n=50; i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  if timeout 25 curl -4 -fsS --connect-timeout 10 --max-time 20 http://127.0.0.1:8080/ -o /dev/null 2>/dev/null; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done
echo "guest :8080 curl: ok=$ok fail=$fail of $n"
```

**Non-CUDN namespaces only:** If you ever run the same virt-e2e images on a namespace **without** primary UDN, **`virtctl ssh -i "$CLUSTER_DIR/.virt-e2e/id_ed25519" cloud-user@vmi/<name> -n <ns>`** may work; it is **not** the supported path for this CUDN runbook.

**Expect per BRIEFING:** **masquerade** does **not** rescue internet egress on a primary UDN; both VMs should show **similar statistical** behavior—not a stable 100%. Record **ok/n** for each VM separately.

### 4.3 Track B sign-off (informational)

- [ ] Sample size and **ok/fail** recorded for pod and (if applicable) both VM types.
- [ ] Note which worker hosted the pod/VM during the run (`oc get pod -o wide`, VMI node).
- [ ] Explicit statement in your report: **internet egress is not a supported reliability target for CUDN on OCP 4.21** per BRIEFING.

---

## 5. Optional: path churn and ECMP sensitivity

To see variance without changing config:

1. Repeat **§ 4.1** in several bursts (e.g. three runs of 50 curls) and compare fractions.
2. Delete and recreate `netshoot-cudn` so it schedules on another node (`oc delete pod -n "$NAMESPACE" netshoot-cudn` and let the Deployment recreate it), then rerun **§ 4.1**. Success rate may move; private Track A should still be **solid**.

This supports the BRIEFING narrative: internet is **node and hash dependent**, not “one wrong route table entry.”

---

## 6. KubeVirt — both bindings (stress)

Aligns with **BRIEFING**: compare **l2bridge-class** vs **masquerade** on the **same** pod network namespace.

1. Deploy virt-e2e VMs (use **`OSD_CUDN_REPO`** and **`CLUSTER_DIR`** from §2):

   ```bash
   bash "$OSD_CUDN_REPO/scripts/e2e-virt-live-migration.sh" -C "$CLUSTER_DIR" -n "$NAMESPACE" --skip-tests
   ```

   Or use your own manifests; confirm one VM uses **`binding.name: l2bridge`** and the other **`masquerade: {}`**. Default cloud-init installs **`podman`**, **`mtr`**, **`traceroute`**, and **`tcpdump`** on the guest (new provisioning only unless you reinstall).

   The script prints **`virtctl console`** lines and writes **`$CLUSTER_DIR/.virt-e2e/console-password`** and the **`id_ed25519`** keypair. For CUDN guest checks, use **§ 2.1**: **`make virt.ssh.bridge`** / **`make virt.ssh.masq`** from **`OSD_CUDN_REPO`**, or **`virt-ssh.sh`** one-shots. Console password (fallback): `echo cloud-user; cat "$CLUSTER_DIR/.virt-e2e/console-password"`

2. **First VM (bridge) → echo VM (private path):** Same class as **§ 3.2** (CUDN → VPC, RFC-1918 return), but the client is the **guest** in **`virt-e2e-bridge`** (l2bridge binding). Use **`ECHO_IP`** and **`ECHO_URL`** from §2.

   **Interactive:** `cd "$OSD_CUDN_REPO"` → **`make virt.ssh.bridge`** → at the guest shell, run **`ping -c 5 "${ECHO_IP}"`** and **`curl -sS --connect-timeout 10 --max-time 25 "${ECHO_URL}"`**. The HTTP body (single line) must equal the guest CUDN IP (**`[virt-ssh]`** prints it when the session opens; or **`ip -br a`** on the guest).

   **One-shot from workstation** ( **`oc`** logged in):

   ```bash
   bash "$OSD_CUDN_REPO/scripts/virt-ssh.sh" -C "$CLUSTER_DIR" -n "$NAMESPACE" \
     "${VIRT_E2E_VM_NAME_BRIDGE:-virt-e2e-bridge}" -- ping -c 5 "${ECHO_IP}"

   bash "$OSD_CUDN_REPO/scripts/virt-ssh.sh" -C "$CLUSTER_DIR" -n "$NAMESPACE" \
     "${VIRT_E2E_VM_NAME_BRIDGE:-virt-e2e-bridge}" -- \
     curl -sS --connect-timeout 10 --max-time 25 "${ECHO_URL}"
   ```

   Expected: ping OK; **`curl`** body equals the bridge guest CUDN IP (same idea as **§ 3.2** with **`NETSHOOT_IP`**). If the IP is unclear, run **`make virt.ssh.bridge`** once and note the **`[virt-ssh] … → cloud-user@<ip>`** line, or compare to **`curl`** output from inside the interactive session.

   **Masquerade VM:** repeat with **`make virt.ssh.masq`** (interactive) or pass **`${VIRT_E2E_VM_NAME_MASQ:-virt-e2e-masq}`** to **`virt-ssh.sh`** instead of the bridge name. **`virtctl console`** only if **§ 2.1** is unavailable.

3. **Private stress:** from `netshoot`, ping/curl each VM’s guest IP (guest runs an HTTP service on **8080** in the default virt-e2e cloud-init). Expect high reliability—same class as pod-to-pod.

4. **Internet stress:** from each guest via **§ 4.2** — **`make virt.ssh.bridge`** / **`make virt.ssh.masq`**, then paste loops **A)** and **B)** (or serial console per §4.2 if needed). Expect **no large, consistent advantage** of masquerade over l2bridge for internet.

5. **Migration (optional):** full exercise:

   ```bash
   bash "$OSD_CUDN_REPO/scripts/e2e-virt-live-migration.sh" -C "$CLUSTER_DIR" -n "$NAMESPACE" --run-tests
   ```

   Requires **≥2** schedulable workers. Masquerade paths may show **disruption during migration**; that is a **known** tradeoff, not proof that private routing failed.

---

## 7. What you explicitly do *not* need to prove

- **100% internet success** from CUDN pods or VMs (contradicts BRIEFING).
- **Cloud NAT** as CUDN egress on GCP (BRIEFING: CUDN source IPs are not viable for Cloud NAT in this model).
- **masquerade** as an internet-egress workaround on primary UDN (BRIEFING: SNAT still presents as CUDN to OVN-K).

---

## 8. Automation shortcut

For a scripted **private-path gate** plus **full virt migration suite** and optional internet sampling, run from the **`osd-gcp-cudn-routing` repository root** (where the `Makefile` lives—not from `tf-provider-osd-google` or another clone):

```bash
cd "$OSD_CUDN_REPO"   # repo root from §2 (directory that contains Makefile + cluster_bgp_routing/)
make networking.validate
```

- Failing **CUDN e2e** or **virt --run-tests** means investigate **configuration or capacity**.
- **`--internet-probes`** on the orchestrator only **counts** successes; it does not assert 100%.

Use **`--virt-hints-only`** if you only want VMs + `virtctl` hints without migrations. Guest shell work still uses **`make virt.ssh.bridge`** / **`make virt.ssh.masq`** or **`virt-ssh.sh`** (**§ 2.1**), not **`virtctl ssh`**.

---

## 9. Final report template (paste into your ticket)

```text
Cluster:
Namespace(s):
Date:

Track A (private / RFC-1918):
- Pod→pod stress: PASS/FAIL (loss %, attempts)
- Pod→echo VM stress: ok/fail counts (expect fail=0)
- Echo VM→pod: PASS/FAIL
- Virt bridge VM→echo VM (ping + curl body): PASS/FAIL
- Notes:

Track B (internet / statistical):
- Pod internet curl: ok/total =
- VM l2bridge internet: ok/total =
- VM masquerade internet: ok/total =
- Worker(s) observed:

Conclusion:
- Private CUDN routing: OK / NOT OK
- Internet: characterized only; aligns / does not align with BRIEFING expectations
```

---

## 10. References

- [BRIEFING.md](../BRIEFING.md) — executive summary, path matrix, ECMP chain, recommendations.
- [KNOWLEDGE.md](../KNOWLEDGE.md) — deeper evidence, firewall, MSS, hub return path.
- [scripts/e2e-cudn-connectivity.sh](../scripts/e2e-cudn-connectivity.sh) — automated pod ↔ echo VM checks.
- [scripts/e2e-virt-live-migration.sh](../scripts/e2e-virt-live-migration.sh) — virt VMs, migrations, concurrent probes.
- [scripts/virt-ssh.sh](../scripts/virt-ssh.sh) — **`make virt.ssh.bridge`** / **`make virt.ssh.masq`**; optional **`-- <remote command>`** for one-shots (**§ 2.1**).
