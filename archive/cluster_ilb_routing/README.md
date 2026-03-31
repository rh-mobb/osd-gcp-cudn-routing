# Reference deployment: `cluster_ilb_routing`

Root Terraform stack for **ILB-based CUDN routing**: composes Git-sourced **`osd-vpc`** and **`osd-cluster`** with local [**`modules/osd-ilb-routing`**](../modules/osd-ilb-routing/README.md).

**Start here if** you want the simplest GCP path (internal NLB + static VPC route) and are fine with **stub** BGP (`FRRConfiguration` with a dummy neighbor). For dynamic routing via **Cloud Router + NCC**, use [**`cluster_bgp_routing/`**](../../cluster_bgp_routing/README.md).

| Topic | Location |
|-------|----------|
| Repo overview (BGP primary) | [README.md](../../README.md) |
| ILB vs BGP comparison | [ILB-vs-BGP.md](../ILB-vs-BGP.md) |
| WIF (apply before this stack) | [wif_config/README.md](../../wif_config/README.md) |
| ILB module only (reuse elsewhere) | [modules/osd-ilb-routing/README.md](../modules/osd-ilb-routing/README.md) |
| BGP reference stack | [cluster_bgp_routing/README.md](../../cluster_bgp_routing/README.md) |
| Production (this stack) | [PRODUCTION.md](PRODUCTION.md) |
| Production (shared + controller) | [PRODUCTION.md](../../PRODUCTION.md) |
| Archived `ilb-apply.sh` env vars | [scripts/README.md](../../scripts/README.md) |

---

## Quick start (pod and echo VM)

Use this after the second Terraform apply includes **`enable_ilb_routing=true`** and **`enable_echo_client_vm=true`**, **`configure-routing.sh`** has run, and **`oc`** is logged in.

**Recommended (from repository root):**

```bash
bash scripts/e2e-cudn-connectivity.sh -C "$(pwd)/archive/cluster_ilb_routing"
```

**Same from this directory:**

```bash
../../scripts/e2e-cudn-connectivity.sh
```

### Manual `ping` / `curl`

Run from **`archive/cluster_ilb_routing/`** so **`terraform output`** and **`./scripts/…`** resolve.

```bash
cd archive/cluster_ilb_routing

./scripts/deploy-cudn-test-pods.sh

# Pod → echo VM (ping then curl). Use the CUDN interface (often ovn-udn1) so traffic
# leaves via the advertised network; adjust if your pod’s `ip a` shows a different name.
ECHO_IP="$(terraform output -raw echo_client_vm_internal_ip)"
oc exec -n cudn1 netshoot-cudn -- ping -I ovn-udn1 -c 3 "$ECHO_IP"

ECHO_URL="$(terraform output -raw echo_client_http_url)"
oc exec -n cudn1 netshoot-cudn -- sh -c \
  'for i in 1 2 3 4 5; do curl -sS --connect-timeout 5 --max-time 15 "$1" && exit 0; sleep 2; done; exit 1' \
  sh "$ECHO_URL"

# Echo VM → pod: resolve the pod’s primary CUDN IP (not `oc get pod -o wide`), then ping + curl
POD_IP="$(./scripts/cudn-pod-ip.sh -n cudn1 icanhazip-cudn)"
gcloud compute ssh "$(terraform output -raw cluster_name)-echo-client" \
  --project="$(terraform output -raw gcp_project_id)" \
  --zone="$(terraform output -raw echo_client_vm_zone)" \
  --tunnel-through-iap \
  --command="ping -c 3 ${POD_IP} && curl -sS --connect-timeout 5 --max-time 15 http://${POD_IP}/"
```

Expect the **pod’s CUDN address** in the **`curl`** response from **`ECHO_URL`**. If **ping** from the VM fails but **curl** works, ICMP may be blocked—rely on **`curl`**.

---

## Architecture

### High-level data flow

```text
┌───────────────────────────────────────────────────────────────────────────┐
│                              GCP VPC (10.0.0.0/16)                       │
│                                                                           │
│  ┌──────────────┐     VPC Route                   ┌───────────────────┐  │
│  │ External Host │  10.100.0.0/16 ──────────────► │  Internal LB      │  │
│  │ 10.0.x.x     │  next-hop: ILB                  │  (Passthrough)    │  │
│  └──────┬───────┘                                  │  ECMP 5-tuple     │  │
│         │                                          └──┬─────┬─────┬──┘  │
│         │                                             │     │     │      │
│         │            ┌────────────────────────────────┘     │     └──┐   │
│         │            ▼                                      ▼        ▼   │
│         │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│         │   │  Worker 1    │  │  Worker 2    │  │  Worker 3    │        │
│         │   │  canIpFwd    │  │  canIpFwd    │  │  canIpFwd    │        │
│         │   │  bare metal  │  │  bare metal  │  │  bare metal  │        │
│         │   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │
│         │          │                 │                  │                 │
│         │   ┌──────▼─────────────────▼──────────────────▼──────────┐     │
│         │   │              OVN-Kubernetes Geneve Overlay           │     │
│         │   │   CUDN: 10.100.0.0/16 · SNAT conditional (internal)   │     │
│         │   └──────────────────────────────────────────────────────┘     │
│  ┌──────▼───────┐                                                       │
│  │ GCP Health   │  TCP 10250 (kubelet) · probe ranges 130.211 / 35.191    │
│  └──────────────┘                                                       │
└───────────────────────────────────────────────────────────────────────────┘
```

### Ingress (external → pod)

1. Packet to a CUDN IP matches the **static VPC route** → **internal passthrough NLB**.
2. ILB **ECMP** picks a healthy worker (5-tuple hash).
3. **`canIpForward=true`** allows delivery to a non-local dest IP.
4. **OVN-Kubernetes** Geneve-forwards to the node hosting the pod (or local delivery).

### Egress (pod → external)

**RouteAdvertisements** configures **conditional SNAT**: only traffic to other cluster-internal ranges is SNATted; external-bound traffic keeps the **pod CUDN IP**.

### GCP components (ILB module)

| Component | Role |
|-----------|------|
| Internal passthrough NLB | ECMP to workers; passthrough (no proxy). |
| `google_compute_route` | CUDN CIDR → ILB next hop. |
| Health check (TCP 10250) | Kubelet port; unhealthy nodes dropped from pool (~15s). |
| Instance groups | Per-zone backends. |
| Firewalls | LB probes; **worker subnet → CUDN** (echo VM / test VMs → pods). |
| **`canIpForward`** | Set post-create via `gcloud` export / `update-from-file` (see `configure-routing.sh`). |

### OpenShift / OVN

| Component | Role |
|-----------|------|
| **CUDN** (`ClusterUserDefinedNetwork`) | Layer2 overlay; primary UDN IP often in **`k8s.ovn.org/pod-networks`**, not only **`status.podIPs`**. |
| **RouteAdvertisements** | Conditional SNAT (works without live BGP). |
| **FRRConfiguration (stub)** | Dummy neighbor (`192.0.2.1`) so OVN can merge templates; **no** real BGP session in the ILB PoC. |
| **Network.operator** | Enable FRR + route advertisements. |

**Conditional SNAT** (observe with `ovn-nbctl list nat` on an `ovnkube-node` pod): advertised CUDN NAT rules match **cluster-internal destinations** only; default pod network uses empty match (full SNAT).

### Comparison with ROSA-BGP on AWS (ILB path)

| Aspect | ROSA-BGP | This ILB stack |
|--------|----------|----------------|
| Route injection | Dynamic (Route Server) | Static route → ILB |
| Load spread | Active/standby style | ILB ECMP |
| IP forwarding | ENI src/dst check off | GCE `canIpForward` |
| FRR | Real peers | Stub neighbor |

### ILB vs GKE familiarity

This design is **not** GKE VPC-native pod CIDRs. It **is** similar to common **internal LB + static route + health check** patterns. See [ILB-vs-BGP.md § ILB, GKE, and GCP support familiarity](../ILB-vs-BGP.md#ilb-gke-and-gcp-support-familiarity).

---

## Variables and apply order

- **Authoritative inputs:** [`variables.tf`](variables.tf), [`terraform.tfvars.example`](terraform.tfvars.example). **Firewall:** `worker_subnet_to_cudn_firewall_mode` (`all` \| **`e2etest`** \| `none`), `routing_worker_target_tags` (optional tags on ILB backend workers). **Remote state:** [`backend.tf.example`](backend.tf.example), [docs/terraform-backend-gcs.md](../../docs/terraform-backend-gcs.md).
- **Minimum before apply:** set **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`** in the environment (or uncomment / set the same in **`terraform.tfvars`**). Values must match **`wif_config`**. Review **`terraform.tfvars.example`** for other knobs (region, node count, routing flags, etc.).
- **Flow:** WIF first → **first apply** here with `enable_ilb_routing = false` (VPC + cluster only) → wait for **`*-worker-*`** VMs → **second apply** with `enable_ilb_routing = true` (and optionally `enable_echo_client_vm = true`).

---

## One-shot orchestration

From the **repo root**:

```bash
bash archive/scripts/ilb-apply.sh
bash scripts/e2e-cudn-connectivity.sh -C "$(pwd)/archive/cluster_ilb_routing"   # optional
# When finished — Terraform destroys this stack then wif_config/ (clean OpenShift CRs if needed; see § Teardown):
bash archive/scripts/ilb-destroy.sh
```

Equivalent to: `wif_config` apply → this directory’s Terraform apply → wait workers → apply with `-var='enable_ilb_routing=true' -var='enable_echo_client_vm=true'` → `oc login` → `./scripts/configure-routing.sh` (from this directory in the script). The e2e script is [`scripts/e2e-cudn-connectivity.sh`](../../scripts/e2e-cudn-connectivity.sh).

**Destroy:** prefer **`bash archive/scripts/ilb-destroy.sh`** from the repo root, or `terraform destroy` here after cleaning OpenShift objects (§ Teardown).

**Terraform passthrough:** `bash archive/scripts/ilb-apply.sh` with the same `TF_VARS` / `EXTRA_TF_VARS` env pattern as **`make bgp.run`** (see root `Makefile`). **`OC_LOGIN_EXTRA_ARGS`** for untrusted API certs — [scripts/README.md](../../scripts/README.md).

---

## Manual deployment (equivalent to `ilb.run`)

### 1. Variables

```bash
cd archive/cluster_ilb_routing
cp terraform.tfvars.example terraform.tfvars
# Set gcp_project_id, cluster_name, …
```

### 2. WIF

```bash
# From repo root
make wif.apply
```

Same `cluster_name` and `gcp_project_id` as this `terraform.tfvars`.

### 3. First apply (no ILB)

```bash
cd archive/cluster_ilb_routing
terraform init -upgrade
terraform apply
```

### 4. Second apply (ILB)

After workers exist:

```bash
terraform apply -var='enable_ilb_routing=true' -var='enable_echo_client_vm=true'
```

Discovery: **`scripts/discover-workers.sh`** (via `data.external`). If `worker_instances` output is empty, check `gcloud compute instances list`.

### 5. OpenShift login

```bash
oc login "$(terraform output -raw api_url)" \
  -u "$(terraform output -raw admin_username)" \
  -p "$(terraform output -raw admin_password)"
```

### 6. `configure-routing.sh`

Run **from this directory** so `terraform output` resolves.

**`--cudn-cidr`** (and **`--cudn-name`**, **`--namespace`**) must match Terraform / CUDN CRs (default CIDR **`10.100.0.0/16`**, CUDN name **`ilb-routing-cudn`**, namespace **`cudn1`**).

```bash
./scripts/configure-routing.sh \
  --project "$(terraform output -raw gcp_project_id)" \
  --region "$(terraform output -raw gcp_region)" \
  --cluster "$(terraform output -raw cluster_name)"
```

The script: **`canIpForward`** on workers → patch **Network.operator** (FRR + route advertisements) → CUDN namespace → **`ClusterUserDefinedNetwork`** → **stub `FRRConfiguration`** → **`RouteAdvertisements`**. Do **not** set **`targetVRF`** to the string `default` on RA (use default/unset for default VRF).

---

## Verification

```bash
oc get ra
oc get frrconfiguration -n openshift-frr-k8s
oc exec -n openshift-ovn-kubernetes \
  "$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o name | head -1)" \
  -c ovnkube-controller -- ovn-nbctl list nat
```

CUDN NAT entries should show a **non-empty** conditional **match**, not `match: ""` for the advertised network.

---

## End-to-end checks

**Pod ↔ echo VM (`ping` / `curl`):** [§ Quick start (pod and echo VM)](#quick-start-pod-and-echo-vm) (from this directory, **`oc`** logged in).

**One-shot automated check** (runs shared **`deploy-cudn-test-pods.sh`**, then pod ↔ echo VM **`ping`** / **`curl`** with IP assertions): from the repo root **`bash scripts/e2e-cudn-connectivity.sh -C "$(pwd)/archive/cluster_ilb_routing"`**, or from this directory **`../../scripts/e2e-cudn-connectivity.sh`**.

### Test pods

```bash
./scripts/deploy-cudn-test-pods.sh
```

Options: **`-n`**, **`--timeout`**, **`--no-wait`**. Default namespace **`cudn1`** — match **`configure-routing.sh --namespace`**.

**CUDN IP for curl/ping from VPC:** use **`./scripts/cudn-pod-ip.sh`** (annotations **`k8s.ovn.org/pod-networks`**, etc.), not necessarily **`oc get pod -o wide`**.

The quick start’s **`curl`** to **`ECHO_URL`** uses a **retry loop** because **intermittent curl** to the echo VM is a known quirk.

### Optional: client VM on worker subnet

Use a small VM on the **worker subnet** to ping/curl CUDN IPs; you need a route to **`10.100.0.0/16`** (Terraform adds **→ ILB**) and firewall allow **worker subnet → CUDN** (module rule **`${cluster_name}-worker-subnet-to-cudn`**). For **IAP SSH** without public IP, allow **`35.235.240.0/20`** → tcp/22 on the VPC. Full snippet and IAP notes lived in the historical root README — pattern: `gcloud compute instances create` on worker subnet, then ping/curl **`POD_IP`** from **`cudn-pod-ip.sh`**.

### Firewalls (VM ↔ CUDN)

- **Pod → echo VM:** module allows **`cudn_cidr` → echo VM**.
- **Worker subnet → CUDN:** module allows **all protocols** from worker subnet CIDR to **`cudn_cidr`** so echo VM / jump hosts can reach pods (complements **`osd-vpc`** rules that don’t treat CUDN as “internal” both-ends).
- **Org / hierarchical firewall policies** can still deny — audit if tests fail.

---

## Scripts in this directory

| Script | Purpose |
|--------|---------|
| `discover-workers.sh` | Terraform **`data.external`**: `selfLink`, `zone` for workers (`-worker-` in name). |
| `configure-routing.sh` | Post-apply GCE + OpenShift (see § Manual deployment). |
| `deploy-cudn-test-pods.sh` | **netshoot-cudn** + **icanhazip-cudn** (exec of [`scripts/deploy-cudn-test-pods.sh`](../../scripts/deploy-cudn-test-pods.sh)). |
| `cudn-pod-ip.sh` | Resolve primary UDN/CUDN IP from annotations. |

---

## Teardown

```bash
oc delete namespace cudn1
oc delete clusteruserdefinednetwork ilb-routing-cudn
oc delete routeadvertisements default
oc delete frrconfiguration stub-config -n openshift-frr-k8s

cd archive/cluster_ilb_routing
terraform destroy
```

Then destroy WIF from repo root: **`make wif.destroy`**.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Empty **`worker_instances`** / ILB plan fails | Workers are OCM-provisioned. **`gcloud compute instances list`** for **`*-worker-*`** in the expected zone; re-apply with **`enable_ilb_routing=true`**. |
| WIF / cluster errors | WIF applied first; same **`cluster_name`** / **`gcp_project_id`** as this stack. |
| **`oc login`** / API cert | **`OC_LOGIN_EXTRA_ARGS='--insecure-skip-tls-verify'`** (or fix trust). |
| VPC reachability fails | Hierarchical firewall **deny** rules; ILB backend health; **`cudn_cidr`** alignment. |
| Wrong IP from VPC | Use **`cudn-pod-ip.sh`**, not **`oc get pod -o wide`** alone for primary UDN. |
| Intermittent curl to echo VM | Retry loop (see § Pod → echo VM). |

---

## Security (PoC)

Echo VM has **no public IP**; SSH uses **`gcloud compute ssh --tunnel-through-iap`** with a firewall rule for IAP’s **`35.235.240.0/20`** range on port 22. Enable the **Identity-Aware Proxy API** and grant callers **`iap.tunnelInstances.accessViaIAP`** (or **IAP-secured Tunnel User**). Disable **`enable_echo_client_vm`** outside labs if you do not need the probe VM. Store **`OSDGOOGLE_TOKEN`**, **`admin_password`**, and GCP keys outside VCS (Secret Manager / CI secrets).

---

## Known limitations (ILB-focused)

- **`canIpForward`** resets when instances are replaced — re-run **`configure-routing.sh`** or automate (see [shared PRODUCTION.md](../PRODUCTION.md)).
- **ILB backends** only refresh on **Terraform apply** — drift if workers change without apply.
- **Kubelet health check** does not prove OVN/FRR health.
- **Two-phase apply** required (workers not created by this Terraform root).
- **New CUDN CIDR** → new static route (and often ILB wiring) per prefix unless you extend the module.
- **`RouteAdvertisements` + `PodNetwork`** requires **`nodeSelector: {}`**.
- Keep **`ClusterUserDefinedNetwork` `metadata.name`** under **16** characters for predictable VRF naming.

---

## Future enhancements (ideas)

See [PRODUCTION.md](PRODUCTION.md) for ILB-focused gaps (backends, health probes, static routes / multiple CUDNs). For the **Kubernetes controller** idea, shared drift/security/ops expectations, and **`canIpForward`** automation, see [../PRODUCTION.md](../PRODUCTION.md).
