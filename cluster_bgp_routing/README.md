# Reference deployment: `cluster_bgp_routing`

Root Terraform stack for **BGP-based CUDN routing**: composes Git-sourced **`osd-vpc`** and **`osd-cluster`** with local [**`modules/osd-bgp-routing`**](../modules/osd-bgp-routing/README.md) (Network Connectivity Center **Router Appliance** spoke + **Cloud Router** + per-worker **BGP peers**).

**Start here if** you want **dynamic** VPC routes learned from **FRR on workers** (real BGP to Cloud Router). **Higher** operational and IAM surface than ILB — see [ILB-vs-BGP.md](../ILB-vs-BGP.md).

**Scripts under `scripts/`** are **BGP-only copies** (not shared with **`cluster_ilb_routing/`**).

| Topic | Location |
|-------|----------|
| Repo overview + both quick starts | [README.md](../README.md) |
| ILB vs BGP | [ILB-vs-BGP.md](../ILB-vs-BGP.md) |
| WIF | [wif_config/README.md](../wif_config/README.md) |
| ILB reference stack | [cluster_ilb_routing/README.md](../cluster_ilb_routing/README.md) |
| BGP module only | [modules/osd-bgp-routing/README.md](../modules/osd-bgp-routing/README.md) |
| Production (this stack) | [PRODUCTION.md](PRODUCTION.md) |
| Production (shared + controller) | [PRODUCTION.md](../PRODUCTION.md) |
| `make bgp-apply` env vars | [scripts/README.md](../scripts/README.md) |

---

## Quick start (pod and echo VM)

Use this after **`enable_bgp_routing=true`**, **`enable_echo_client_vm=true`**, **`configure-routing.sh`** (BGP sessions **Established** on workers), and **`oc`** is logged in.

**Recommended (from repository root):**

```bash
make bgp-e2e
```

**Same from this directory:**

```bash
../scripts/e2e-cudn-connectivity.sh
```

### Manual `ping` / `curl`

Run from **`cluster_bgp_routing/`**.

```bash
cd cluster_bgp_routing

./scripts/deploy-cudn-test-pods.sh

# Pod → echo VM (ping then curl). Use the CUDN interface (often ovn-udn1); see `ip a` in the pod if needed.
ECHO_IP="$(terraform output -raw echo_client_vm_internal_ip)"
oc exec -n cudn1 netshoot-cudn -- ping -I ovn-udn1 -c 3 "$ECHO_IP"

ECHO_URL="$(terraform output -raw echo_client_http_url)"
oc exec -n cudn1 netshoot-cudn -- sh -c \
  'for i in 1 2 3 4 5; do curl -sS --connect-timeout 5 --max-time 15 "$1" && exit 0; sleep 2; done; exit 1' \
  sh "$ECHO_URL"

# Echo VM → pod (CUDN IP from annotations, not `oc get pod -o wide`)
POD_IP="$(./scripts/cudn-pod-ip.sh -n cudn1 icanhazip-cudn)"
gcloud compute ssh "$(terraform output -raw cluster_name)-echo-client" \
  --project="$(terraform output -raw gcp_project_id)" \
  --zone="$(terraform output -raw echo_client_vm_zone)" \
  --command="ping -c 3 ${POD_IP} && curl -sS --connect-timeout 5 --max-time 15 http://${POD_IP}/"
```

If **ping** from the VM fails but **curl** works, ICMP may be blocked—use **`curl`**. If the pod never reaches the VM, **`./scripts/debug-gcp-bgp.sh`** and BGP **`Established`** on both workers (see [§ Troubleshooting](#troubleshooting)).

---

## Architecture (summary)

1. **NCC hub** + **Router Appliance spoke** register worker VMs so Cloud Router may peer with them.
2. **Cloud Router** gets exactly **2 interfaces** (primary + redundant HA pair) and **2 BGP peers per worker** (one on each interface, `router_appliance_instance` + worker internal IP).
3. Workers run **FRR** (`FRRConfiguration`) and advertise CUDN prefixes; the VPC learns **`cudn_cidr`** via BGP (no static **`google_compute_route`** to an ILB in this module).
4. **OVN** and **RouteAdvertisements** match the ILB stack: **conditional SNAT** on the CUDN.

**Per-node FRR:** each worker peers with **both** Cloud Router interface IPs. The reference **`configure-routing.sh`** creates one **`FRRConfiguration` per worker** (with 2 neighbors), using **`Node.spec.providerID`** (GCE instance name suffix) to match Terraform’s **`bgp_peer_matrix`**.

**Cloud Router ASN:** default **`64512`** (RFC 6996 private ASN — required by the Terraform provider for **`google_compute_router`**). **`frr_asn`** defaults to **`65003`**; both are outputs and are read by **`configure-routing.sh`**.

Diagram and resource tables: [ILB-vs-BGP.md](../ILB-vs-BGP.md) (**Approach B**).

---

## IAM prerequisites

The identity running **`terraform apply`** needs permissions beyond a minimal OSD WIF setup, for example:

- `roles/networkconnectivity.hubAdmin`
- `roles/networkconnectivity.spokeAdmin`
- `roles/compute.networkAdmin`

Details: [ILB-vs-BGP.md § Additional IAM Requirements](../ILB-vs-BGP.md#additional-iam-requirements). If only your **user ADC** has these roles (not the cluster WIF SA), that is expected for this PoC.

---

## Variables and apply order

- **Authoritative inputs:** [`variables.tf`](variables.tf), [`terraform.tfvars.example`](terraform.tfvars.example).
- **Minimum before apply:** set **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`** (or **`terraform.tfvars`**) so they match **`wif_config`**. Use **`terraform.tfvars.example`** as a guide for additional variables (region, ASNs, BGP toggles, node counts, etc.).
- **Flow:** WIF first (same **`cluster_name`** / **`gcp_project_id`** as this stack) → **first apply** with **`enable_bgp_routing = false`** → wait for **`*-worker-*`** VMs → **`canIpForward=true`** on those workers (**required** before NCC router-appliance spoke; see **`enable-worker-can-ip-forward.sh`**) → **second apply** with **`enable_bgp_routing = true`** (and optionally **`enable_echo_client_vm = true`**).
- **Discovery:** **`scripts/discover-workers.sh`** returns **`name`**, **`selfLink`**, **`zone`**, **`networkIP`**. Terraform checks non-empty **`networkIP`** when BGP is enabled.

**Optional:** **`router_interface_private_ips`** — explicit Cloud Router interface addresses (exactly 2 elements: primary + redundant). Otherwise IPs are **`cidrhost(worker_subnet, bgp_interface_host_offset)`** and **`bgp_interface_host_offset + 1`** — avoid collisions with other hosts in the subnet.

---

## One-shot orchestration

From the **repo root**:

```bash
make bgp-apply
make bgp-e2e          # optional: CUDN pod ↔ echo VM checks (after BGP Established)
# When finished — Terraform destroys this stack then wif_config/ (remove OpenShift objects per § Teardown):
make bgp-destroy
```

**Destroy:** **`make bgp-destroy`** from the repo root (last line above), then remove any remaining OpenShift objects (§ Teardown).

**Worker wait env vars:** **`BGP_APPLY_WORKER_WAIT_ATTEMPTS`**, **`BGP_APPLY_WORKER_WAIT_SLEEP`**, **`BGP_APPLY_MIN_WORKERS`** — [scripts/README.md](../scripts/README.md). **`OC_LOGIN_EXTRA_ARGS`** for API TLS.

**Terraform passthrough:** `make bgp-apply TF_VARS="..." EXTRA_TF_VARS="..."`.

---

## Manual deployment

### 1. Variables

```bash
cd cluster_bgp_routing
cp terraform.tfvars.example terraform.tfvars
# Set gcp_project_id, cluster_name, …
```

Use a **separate** `terraform.tfvars` from **`cluster_ilb_routing/`** if you maintain both stacks (different state).

### 2. WIF

```bash
make wif.apply   # from repo root, or cd wif_config && terraform apply
```

### 3. First apply (BGP off)

```bash
cd cluster_bgp_routing
terraform init -upgrade
terraform apply
```

### 4. Enable `canIpForward` on workers (before BGP Terraform)

**Network Connectivity** rejects router-appliance spokes unless worker VMs already have **`canIpForward: true`**.

```bash
./scripts/enable-worker-can-ip-forward.sh \
  --project "$(terraform output -raw gcp_project_id)" \
  --zone "$(terraform output -raw availability_zone)" \
  --cluster "$(terraform output -raw cluster_name)"
```

### 5. Second apply (BGP + optional echo VM)

```bash
terraform apply \
  -var='enable_bgp_routing=true' \
  -var='enable_echo_client_vm=true'
```

### 6. Login and configure

```bash
oc login "$(terraform output -raw api_url)" \
  -u "$(terraform output -raw admin_username)" \
  -p "$(terraform output -raw admin_password)"
```

From **`cluster_bgp_routing/`**:

```bash
./scripts/configure-routing.sh \
  --project "$(terraform output -raw gcp_project_id)" \
  --region "$(terraform output -raw gcp_region)" \
  --cluster "$(terraform output -raw cluster_name)"
```

The script reads **`terraform output -json bgp_peer_matrix`** and **`cloud_router_asn`** / **`frr_asn`**. Default CUDN name **`bgp-routing-cudn`** (override with **`--cudn-name`** / **`--cudn-cidr`** / **`--namespace`** to match Terraform).

**Before applying new FRR configs**, it deletes existing **`FRRConfiguration`** in **`openshift-frr-k8s`** with label **`cudn.redhat.com/bgp-stack=osd-gcp-bgp`**.

---

## Verification

**OpenShift**

```bash
oc get ra
oc get frrconfiguration -n openshift-frr-k8s
```

One **`FRRConfiguration`** per worker; each targets a single node and peers with **both** Cloud Router interface IPs (2 neighbors).

**OVN NAT** (same idea as ILB stack):

```bash
oc exec -n openshift-ovn-kubernetes \
  "$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o name | head -1)" \
  -c ovnkube-controller -- ovn-nbctl list nat
```

**GCP**

- Cloud Router **BGP session** status in console / **`gcloud compute routers get-status`**
- VPC **routes** for **`cudn_cidr`** learned via dynamic routing
- NCC **spoke** state (Router Appliance instances)

---

## End-to-end checks

Same **`ping`** / **`curl`** sequence as [§ Quick start (pod and echo VM)](#quick-start-pod-and-echo-vm) (run from **`cluster_bgp_routing/`**). Traffic to CUDN follows **learned BGP routes** (not static route → ILB). Optional: test from another VM on the worker subnet using **`cudn-pod-ip.sh`** and a route to **`cudn_cidr`**.

**Automated:** **`make bgp-e2e`** from the repo root, or **`../scripts/e2e-cudn-connectivity.sh`** from this directory.

**Firewalls:** module allows **worker subnet → CUDN** and **TCP 179** within the worker subnet for BGP.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `discover-workers.sh` | **`data.external`**: **`name`**, **`selfLink`**, **`zone`**, **`networkIP`**. |
| `enable-worker-can-ip-forward.sh` | Sets **`canIpForward`** on **`-worker-`** instances (GCE export / **`update-from-file`**). Run **before** second apply with **`enable_bgp_routing=true`** ( **`make bgp-apply`** runs it automatically). |
| `configure-routing.sh` | **`canIpForward`** (idempotent re-run), FRR enable, CUDN, **per-node `FRRConfiguration`**, **`RouteAdvertisements`**. Requires **`terraform`** in PATH. |
| `deploy-cudn-test-pods.sh` | Test pods (exec of [`scripts/deploy-cudn-test-pods.sh`](../scripts/deploy-cudn-test-pods.sh)). |
| `cudn-pod-ip.sh` | CUDN IP from annotations (independent copy). |
| `debug-gcp-bgp.sh` | **`gcloud`** diagnostics: Cloud Router **BGP status**, NCC hub/spoke, **routes** for **`cudn_cidr`**, module **firewall** rules. Run from **`cluster_bgp_routing/`** (`terraform output` must include **`cloud_router_id`**). Optional **`--dir`**. |

---

## Teardown

```bash
oc delete namespace cudn1
oc delete clusteruserdefinednetwork bgp-routing-cudn
oc delete routeadvertisements default
oc delete frrconfiguration -n openshift-frr-k8s -l cudn.redhat.com/bgp-stack=osd-gcp-bgp

cd cluster_bgp_routing
terraform destroy
```

Then **`make wif.destroy`** from the repo root.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| **`bgp_peer_matrix` empty** / configure script exits | Second apply with **`enable_bgp_routing=true`**; workers running; **`terraform output bgp_peer_matrix`**. |
| **No node for instance** in configure script | **`providerID`** on Node must end with the GCE **instance name** from **`gcp compute instances list`**. |
| **`canIpForward` / invalid argument** on **`google_network_connectivity_spoke`** | Run **`./scripts/enable-worker-can-ip-forward.sh`** (or **`make bgp-apply`**, which runs it **before** pass-2 Terraform); then re-apply. |
| **Terraform NCC / router errors** | IAM roles ([§ IAM](#iam-prerequisites)); API enablement; quota. |
| **BGP session down** | **`./scripts/debug-gcp-bgp.sh`**; **`gcloud routers get-status`** + **`oc debug node/…`** — from the worker host, **`nc -vz CLOUD_ROUTER_IP 179`** should succeed. If TCP works but FRR stays **Active** with **No path to specified Neighbor**, workers likely use a **/32** on **br-ex** (GCP); **`configure-routing.sh`** appends **`disable-connected-check`** for each Cloud Router neighbor (**`spec.raw`**). Also verify firewall **tcp/179**, **neighbor** IPs, and **ASN** (**`cloud_router_asn`** / **`frr_asn`**). |
| **Wrong pod IP from VPC** | Use **`./scripts/cudn-pod-ip.sh`**. |
| **`oc login`** issues | **`OC_LOGIN_EXTRA_ARGS`**. |

---

## Security (PoC)

Echo VM SSH and PoC firewalls mirror the ILB module — restrict **`0.0.0.0/0`** or disable the echo VM outside labs. See [modules/osd-bgp-routing/README.md](../modules/osd-bgp-routing/README.md).

---

## Known limitations

Shared with ILB where applicable (**`canIpForward`**, two-phase apply, worker replacement). **BGP-specific:**

- **NCC spoke** and **Cloud Router peers** must be updated when workers are replaced (Terraform re-apply or automation — [PRODUCTION.md](PRODUCTION.md)).
- **Cloud Router interface IP** allocation must not collide with other hosts unless you set **`router_interface_private_ips`**.
- **Per-node `FRRConfiguration`** naming and **`providerID`** matching are PoC-level; production may use a controller.

---

## Makefile targets for this directory only

From repo root: **`make bgp.init`**, **`bgp.plan`**, **`bgp.apply`**, **`bgp.destroy`** run Terraform **only** in **`cluster_bgp_routing/`**.
