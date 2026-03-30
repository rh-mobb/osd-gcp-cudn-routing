# OSD GCP CUDN Routing (ILB and BGP)

**Experimental** — maintained by the **Red Hat Managed OpenShift Black Belt** team; **not** a supported product or production-ready baseline. See [PRODUCTION.md](PRODUCTION.md) for gaps and automation direction.

This repo provides **Terraform** and scripts to run **OpenShift Dedicated on GCP** with a **Cluster User-Defined Network (CUDN)** so pod and KubeVirt VM IPs are **reachable from the VPC without SNAT** on egress to external destinations. VPC/cluster modules come from [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google); the **`osdgoogle`** provider is **`~> 0.1.3`** on the [Terraform Registry](https://registry.terraform.io/providers/rh-mobb/osd-google). Apply [**`wif_config/`**](wif_config/README.md) **before** either cluster stack.

**Two reference roots** (pick one per environment; they do not share scripts):

| Approach | TL;DR | Full guide |
|----------|--------|------------|
| **ILB** | Static VPC route sends the CUDN CIDR to an **internal passthrough NLB**; workers are backends. **Stub** `FRRConfiguration` satisfies RouteAdvertisements. Familiar Compute/LB primitives; **two-phase** `terraform apply`. | [**cluster_ilb_routing/README.md**](cluster_ilb_routing/README.md) |
| **BGP** | **NCC** Router Appliance + **Cloud Router** BGP to each worker; routes learned into the VPC. **Per-node** `FRRConfiguration`. More IAM and moving parts; **two-phase** apply. | [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md) |

Both paths use **OVN-Kubernetes**, **`ClusterUserDefinedNetwork`**, **`RouteAdvertisements`** (conditional SNAT), **`canIpForward`** on workers, and **`configure-routing.sh`** after install — see each stack’s README for defaults (e.g. CUDN name **`ilb-routing-cudn`** vs **`bgp-routing-cudn`**).

**Compare approaches:** [ILB-vs-BGP.md](ILB-vs-BGP.md)

---

## Problem (one minute)

KubeVirt / migration scenarios often need:

- **Preserved pod/VM IPs** and **direct routing** from the VPC (or peered networks).
- **Egress without SNAT** to arbitrary external destinations (OVN default SNATs through the node).

This repo wires **GCP** (ILB or BGP) with **OpenShift** so the CUDN overlay is routable and **RouteAdvertisements** narrow SNAT to cluster-internal destinations only.

---

## Shared prerequisites

- **OCM:** `OSDGOOGLE_TOKEN` or `ocm_token`
- **GCP:** project with OSD entitlements; **`gcloud auth application-default login`**
- **WIF:** [`wif_config/`](wif_config/) applied with the **same** `cluster_name` and `gcp_project_id` as the cluster stack (see below)
- **CLI:** `terraform`, `gcloud`, `oc`, `jq` (BGP **`configure-routing.sh`** also needs `terraform` for outputs)

**Terraform inputs (minimum before `make ilb-apply`, `make bgp-apply`, `make apply`, or `make bgp.apply`):**

Set at least **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`** (they must match **`wif_config`**). Example:

```bash
export TF_VAR_gcp_project_id="my-gcp-project"
export TF_VAR_cluster_name="my-cluster-name"
```

Alternatively, copy **`cluster_ilb_routing/terraform.tfvars.example`** or **`cluster_bgp_routing/terraform.tfvars.example`** to **`terraform.tfvars`** in that directory and set **`gcp_project_id`** / **`cluster_name`** there (plus any other variables you need). Use the **`.example`** file as the checklist for optional settings (region, node counts, feature flags, etc.). **Remote state:** [docs/terraform-backend-gcs.md](docs/terraform-backend-gcs.md) and **`backend.tf.example`** in each cluster directory.

**BGP only:** extra IAM for NCC / Cloud Router on the identity running `terraform apply` — [ILB-vs-BGP.md § IAM](ILB-vs-BGP.md#additional-iam-requirements).

---

## Quick start — ILB

From the **repository root** after **`wif_config`** is applied and **`TF_VAR_*`** / **`terraform.tfvars`** are set (see [§ Shared prerequisites](#shared-prerequisites)):

```bash
make ilb-apply
make ilb-e2e
```

**`ilb-apply`** runs WIF → cluster (ILB off) → wait for workers → second apply (ILB + echo VM) → `oc login` → **`cluster_ilb_routing/scripts/configure-routing.sh`**.

**`ilb-e2e`** runs end-to-end connectivity (**pod ↔ echo VM**: deploy test pods, `ping` / `curl`, IP assertions). Use the same shell with **`oc`** and **`gcloud`** still working.

Same as **`scripts/e2e-cudn-connectivity.sh -C cluster_ilb_routing`** from the repo root. Options (namespace, `--skip-deploy`, `--allow-icmp-fail`, …): [scripts/README.md](scripts/README.md#cudn-connectivity-ilb-or-bgp-stack).

**Manual checks** (from **`cluster_ilb_routing/`**): [§ Quick start (pod and echo VM)](cluster_ilb_routing/README.md#quick-start-pod-and-echo-vm). Use **`ovn-udn1`** (or the interface from **`ip a`** in netshoot) for **`ping -I`**. If **ping** fails but **curl** works, ICMP may be blocked—pass **`--allow-icmp-fail`** to **`scripts/e2e-cudn-connectivity.sh`** (see [scripts/README § CUDN connectivity](scripts/README.md#cudn-connectivity-ilb-or-bgp-stack)).

**When you are done**, tear down (**Terraform** destroys **`cluster_ilb_routing/`**, then **`wif_config/`**). You may need to remove OpenShift CRs before or after — see [cluster_ilb_routing § Teardown](cluster_ilb_routing/README.md#teardown).

```bash
make ilb-destroy
```

More detail: [**cluster_ilb_routing/README.md**](cluster_ilb_routing/README.md).

---

## Quick start — BGP

Satisfy **BGP IAM**; set **`TF_VAR_gcp_project_id`** / **`TF_VAR_cluster_name`** (or **`cluster_bgp_routing/terraform.tfvars`**) like ILB — see [§ Shared prerequisites](#shared-prerequisites) and [`cluster_bgp_routing/terraform.tfvars.example`](cluster_bgp_routing/terraform.tfvars.example). Then from the repo root:

```bash
make bgp-apply
make bgp-e2e
```

**`bgp-apply`** applies WIF, then a single Terraform apply with **`enable_bgp_routing=true`**, and runs **`configure-routing.sh`** (one-time FRR/CUDN/RouteAdvertisements setup). The [BGP routing controller](controller/python/README.md) manages the dynamic resources (NCC spoke, BGP peers, canIpForward, FRRConfiguration).

**`bgp-e2e`** is the same CUDN **`ping`** / **`curl`** checks as ILB (once BGP is **Established** on workers). Equivalent to **`scripts/e2e-cudn-connectivity.sh -C cluster_bgp_routing`**. Script options: [scripts/README § CUDN connectivity](scripts/README.md#cudn-connectivity-ilb-or-bgp-stack).

**Manual checks:** [cluster_bgp_routing § Quick start (pod and echo VM)](cluster_bgp_routing/README.md#quick-start-pod-and-echo-vm). If the pod cannot reach the VM, run **`./scripts/debug-gcp-bgp.sh`** from **`cluster_bgp_routing/`**.

**When you are done**, tear down (**Terraform** destroys **`cluster_bgp_routing/`**, then **`wif_config/`**). Remove OpenShift objects as needed — [cluster_bgp_routing § Teardown](cluster_bgp_routing/README.md#teardown) (**`FRRConfiguration`** labels, etc.).

```bash
make bgp-destroy
```

More detail: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

---

## Makefile targets (summary)

| Target | Directory / action |
|--------|-------------------|
| `ilb-apply` / `ilb-destroy` | Full ILB flow / destroy `cluster_ilb_routing` then `wif_config` |
| `ilb-e2e` | Run [`scripts/e2e-cudn-connectivity.sh`](scripts/e2e-cudn-connectivity.sh) against **`cluster_ilb_routing/`** (`oc`, `gcloud`, `jq`, `terraform` required) |
| `bgp-apply` / `bgp-destroy` | Full BGP flow / destroy `cluster_bgp_routing` then `wif_config` |
| `bgp-e2e` | Same e2e script against **`cluster_bgp_routing/`** |
| `init`, `plan`, `apply`, `destroy` | **`cluster_ilb_routing/`** only |
| `bgp.init`, `bgp.plan`, `bgp.apply`, `bgp.destroy` | **`cluster_bgp_routing/`** only |
| `wif.*` | **`wif_config/`** |
| `fmt`, `validate` | All stacks + modules |

Terraform extras: `TF_VARS`, `EXTRA_TF_VARS`. Env vars for apply scripts: [scripts/README.md](scripts/README.md).

---

## Repository layout

```text
wif_config/                 # WIF — apply first
modules/osd-ilb-routing/    # Reusable ILB module
modules/osd-bgp-routing/    # Reusable BGP (NCC + Cloud Router) module
cluster_ilb_routing/        # ILB reference root + scripts/ + PRODUCTION.md
cluster_bgp_routing/        # BGP reference root + scripts/ + PRODUCTION.md (independent copies)
scripts/                    # ilb-apply.sh, bgp-apply.sh, …
```

---

## Roadmap / TODO

- **BGP — dedicated routing nodes:** Today the reference stack registers **worker** VMs as NCC Router Appliance instances and peers BGP from Cloud Router to each. A future direction is **separate node pool / machines** (or non-schedulable nodes) used only for forwarding and BGP, so cluster scaling and worker replacement do not directly imply NCC spoke and peer churn. (No implementation or timeline here — tracking intent only.)

---

## More documentation

| Doc | Purpose |
|-----|---------|
| [cluster_ilb_routing/README.md](cluster_ilb_routing/README.md) | ILB architecture, deployment, verification, teardown, troubleshooting |
| [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md) | BGP architecture, IAM, deployment, verification, teardown |
| [ILB-vs-BGP.md](ILB-vs-BGP.md) | Side-by-side comparison, migration notes |
| [PRODUCTION.md](PRODUCTION.md) | Shared: controller, drift, security, cross-VPC; links to [ILB](cluster_ilb_routing/PRODUCTION.md) / [BGP](cluster_bgp_routing/PRODUCTION.md) stack checklists |
| [wif_config/README.md](wif_config/README.md) | WIF apply order and variables |
| [modules/osd-ilb-routing/README.md](modules/osd-ilb-routing/README.md) | Consume ILB module from another root |
| [modules/osd-bgp-routing/README.md](modules/osd-bgp-routing/README.md) | Consume BGP module from another root |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

PRs: run **`make fmt`** before submission.
