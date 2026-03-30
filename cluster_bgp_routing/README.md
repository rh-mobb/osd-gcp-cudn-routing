# Reference deployment: `cluster_bgp_routing`

Root Terraform stack for **BGP-based CUDN routing**: composes Git-sourced **`osd-vpc`** and **`osd-cluster`** with local [**`modules/osd-bgp-routing`**](../modules/osd-bgp-routing/README.md) (NCC hub + Cloud Router + interfaces + firewalls).

The **controller** ([`controller/python/`](../controller/python/README.md)) owns the **dynamic** resources: NCC spoke, Cloud Router BGP peers, `canIpForward`, and `FRRConfiguration` CRs.

**Start here if** you want **dynamic** VPC routes learned from **FRR on workers** (real BGP to Cloud Router). **Higher** operational and IAM surface than ILB — see [ILB-vs-BGP.md](../ILB-vs-BGP.md).

**Scripts under `scripts/`** are **BGP-only copies** (not shared with **`cluster_ilb_routing/`**).

| Topic | Location |
|-------|----------|
| Repo overview + both quick starts | [README.md](../README.md) |
| ILB vs BGP | [ILB-vs-BGP.md](../ILB-vs-BGP.md) |
| WIF | [wif_config/README.md](../wif_config/README.md) |
| ILB reference stack | [cluster_ilb_routing/README.md](../cluster_ilb_routing/README.md) |
| BGP module only | [modules/osd-bgp-routing/README.md](../modules/osd-bgp-routing/README.md) |
| BGP routing controller | [controller/python/README.md](../controller/python/README.md) |
| Production (this stack) | [PRODUCTION.md](PRODUCTION.md) |
| Production (shared + controller) | [PRODUCTION.md](../PRODUCTION.md) |

---

## Quick start (pod and echo VM)

Use this after **`enable_bgp_routing=true`**, **controller deployed**, **`configure-routing.sh`** (one-time setup), and **`oc`** is logged in.

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
  --tunnel-through-iap \
  --command="ping -c 3 ${POD_IP} && curl -sS --connect-timeout 5 --max-time 15 http://${POD_IP}/"
```

If **ping** from the VM fails but **curl** works, ICMP may be blocked—use **`curl`**. If the pod never reaches the VM, **`./scripts/debug-gcp-bgp.sh`** and BGP **`Established`** on all router nodes (see [Troubleshooting](#troubleshooting)).

---

## Architecture (summary)

1. **Terraform** creates the **static** infrastructure: NCC hub, Cloud Router with 2 interfaces (HA pair), firewalls.
2. The **controller** creates and manages the **dynamic** resources: NCC spoke (router appliance instances), Cloud Router BGP peers (2 per node), `canIpForward` on GCE instances, and `FRRConfiguration` CRs.
3. Router nodes run **FRR** and advertise CUDN prefixes; the VPC learns **`cudn_cidr`** via BGP.
4. **OVN** and **RouteAdvertisements** match the ILB stack: **conditional SNAT** on the CUDN.

**Cloud Router ASN:** default **`64512`** (RFC 6996 private ASN — required by the Terraform provider for **`google_compute_router`**). **`frr_asn`** defaults to **`65003`**; both are outputs consumed by the controller.

Diagram and resource tables: [ILB-vs-BGP.md](../ILB-vs-BGP.md) (**Approach B**).

---

## IAM prerequisites

The identity running **`terraform apply`** needs:

- `roles/networkconnectivity.hubAdmin`
- `roles/compute.networkAdmin`

The **controller** needs a separate GCP SA with spoke and peer permissions — see [controller/python/README.md § GCP IAM](../controller/python/README.md#gcp-iam-custom-role--least-privilege).

Details: [ILB-vs-BGP.md § Additional IAM Requirements](../ILB-vs-BGP.md#additional-iam-requirements).

---

## Variables and apply order

- **Authoritative inputs:** [`variables.tf`](variables.tf), [`terraform.tfvars.example`](terraform.tfvars.example). **Firewall:** `worker_subnet_to_cudn_firewall_mode` (`all` \| **`e2etest`** \| `none`), `routing_worker_target_tags` (optional GCP network tags for router nodes). **Cloud Router IPs:** `reserve_cloud_router_interface_ips` (default **true**). **Remote state:** [`backend.tf.example`](backend.tf.example), [docs/terraform-backend-gcs.md](../docs/terraform-backend-gcs.md).
- **Minimum before apply:** set **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`** (or **`terraform.tfvars`**) so they match **`wif_config`**. Use **`terraform.tfvars.example`** as a guide for additional variables (region, ASNs, BGP toggles, node counts, etc.).
- **Flow:** WIF first → **single apply** with **`enable_bgp_routing = true`** (and optionally **`enable_echo_client_vm = true`**) → `oc login` → **`configure-routing.sh`** (one-time: FRR enable, CUDN, RouteAdvertisements) → **deploy the controller** (see [controller/python/README.md](../controller/python/README.md)).

**Optional:** **`router_interface_private_ips`** — explicit Cloud Router interface addresses (exactly 2 elements: primary + redundant). Otherwise IPs are **`cidrhost(worker_subnet, bgp_interface_host_offset)`** and **`bgp_interface_host_offset + 1`** — avoid collisions with other hosts in the subnet.

---

## One-shot orchestration

From the **repo root**:

```bash
make bgp-apply
make bgp-e2e          # optional: CUDN pod ↔ echo VM checks (after controller deployed + BGP Established)
# When finished — Terraform destroys this stack then wif_config/ (remove OpenShift objects per § Teardown):
make bgp-destroy
```

**Destroy:** **`make bgp-destroy`** from the repo root (last line above), then remove any remaining OpenShift objects (Teardown).

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

### 3. Apply (static infra + cluster)

```bash
cd cluster_bgp_routing
terraform init -upgrade
terraform apply \
  -var='enable_bgp_routing=true' \
  -var='enable_echo_client_vm=true'
```

### 4. Login and one-time configure

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

### 5. Deploy the controller

See [controller/python/README.md § Build and deploy](../controller/python/README.md#build-and-deploy). Feed the ConfigMap with values from `terraform output`:

```bash
terraform output -raw ncc_hub_name         # → NCC_HUB_NAME
terraform output -raw ncc_spoke_name       # → NCC_SPOKE_NAME
terraform output -raw cloud_router_name    # → CLOUD_ROUTER_NAME
terraform output -raw gcp_project_id       # → GCP_PROJECT
terraform output -raw cluster_name         # → CLUSTER_NAME
terraform output -raw gcp_region           # → CLOUD_ROUTER_REGION
```

---

## Verification

**OpenShift**

```bash
oc get ra
oc get frrconfiguration -n openshift-frr-k8s
```

One **`FRRConfiguration`** per router node (created by the controller); each targets a single node and peers with **both** Cloud Router interface IPs (2 neighbors).

**OVN NAT** (same idea as ILB stack):

```bash
oc exec -n openshift-ovn-kubernetes \
  "$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o name | head -1)" \
  -c ovnkube-controller -- ovn-nbctl list nat
```

**GCP**

- Cloud Router **BGP session** status in console / **`gcloud compute routers get-status`**
- VPC **routes** for **`cudn_cidr`** learned via dynamic routing
- NCC **spoke** state (Router Appliance instances — created by controller)

---

## End-to-end checks

Same **`ping`** / **`curl`** sequence as [Quick start (pod and echo VM)](#quick-start-pod-and-echo-vm) (run from **`cluster_bgp_routing/`**). Traffic to CUDN follows **learned BGP routes** (not static route → ILB).

**Automated:** **`make bgp-e2e`** from the repo root, or **`../scripts/e2e-cudn-connectivity.sh`** from this directory.

**Firewalls:** module allows **worker subnet → CUDN** and **TCP 179** within the worker subnet for BGP.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `configure-routing.sh` | **One-time setup:** FRR enable, CUDN namespace + `ClusterUserDefinedNetwork`, `RouteAdvertisements`. Requires **`oc`** in PATH. |
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

# Remove the controller
kubectl delete -k controller/python/deploy/

cd cluster_bgp_routing
terraform destroy
```

Then **`make wif.destroy`** from the repo root.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| **No FRRConfiguration CRs** | Controller deployed and running? Nodes have the expected label (`node-role.kubernetes.io/infra` by default)? Check controller logs. |
| **NCC spoke missing** | Controller creates the spoke on first reconciliation. Check controller logs for GCP IAM errors (`networkconnectivity.spokes.create`). |
| **Terraform NCC / router errors** | IAM roles ([IAM](#iam-prerequisites)); API enablement; quota. |
| **BGP session down** | **`./scripts/debug-gcp-bgp.sh`**; **`gcloud routers get-status`** + **`oc debug node/…`** — from the worker host, **`nc -vz CLOUD_ROUTER_IP 179`** should succeed. If TCP works but FRR stays **Active** with **No path to specified Neighbor**, workers likely use a **/32** on **br-ex** (GCP); the controller appends **`disable-connected-check`** for each Cloud Router neighbor (**`spec.raw`**). Also verify firewall **tcp/179**, **neighbor** IPs, and **ASN** (**`cloud_router_asn`** / **`frr_asn`**). |
| **Wrong pod IP from VPC** | Use **`./scripts/cudn-pod-ip.sh`**. |
| **`oc login`** issues | **`OC_LOGIN_EXTRA_ARGS`**. |

---

## Security (PoC)

Echo VM has **no public IP**; SSH is **`gcloud compute ssh --tunnel-through-iap`** (see [modules/osd-bgp-routing/README.md](../modules/osd-bgp-routing/README.md)). Other PoC firewalls still warrant review outside labs.

---

## Known limitations

Shared with ILB where applicable (**`canIpForward`**, worker replacement). **BGP-specific:**

- The **controller** must be deployed and healthy for routing to converge after node changes.
- **Cloud Router interface IP** allocation must not collide with other hosts unless you set **`router_interface_private_ips`**.
- **Per-node `FRRConfiguration`** naming and **`providerID`** matching are handled by the controller; the Python/kopf version is a prototype — production may use the Go controller.

---

## Makefile targets for this directory only

From repo root: **`make bgp.init`**, **`bgp.plan`**, **`bgp.apply`**, **`bgp.destroy`** run Terraform **only** in **`cluster_bgp_routing/`**.
