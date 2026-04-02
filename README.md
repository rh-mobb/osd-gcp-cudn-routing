# OSD GCP CUDN Routing (BGP)

**Experimental** — maintained by the **Red Hat Managed OpenShift Black Belt** team; **not** a supported product or production-ready baseline. See [PRODUCTION.md](PRODUCTION.md) for gaps and automation direction.

This repo provides **Terraform** and scripts to run **OpenShift Dedicated on GCP** with a **Cluster User-Defined Network (CUDN)** so pod and KubeVirt VM IPs are **reachable from the VPC without SNAT** on egress to external destinations. VPC/cluster modules come from [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google); the **`osdgoogle`** provider is **`~> 0.1.3`** on the [Terraform Registry](https://registry.terraform.io/providers/rh-mobb/osd-google). **`make bgp.run`** applies [**`wif_config/`**](wif_config/README.md) first; expert **`terraform apply`** from **`cluster_bgp_routing/`** alone still expects WIF to exist in OCM.

**Active reference stack — BGP:** **NCC** Router Appliance + **Cloud Router** BGP to **all non-infra worker nodes** (controller labels **`node-role.kubernetes.io/bgp-router`**); routes learned into the VPC. **Per-node** `FRRConfiguration`. **Single** `terraform apply` (static infra) plus the [BGP controller](controller/python/README.md) for spoke, peers, and FRR CRs. Full guide: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

The **internal load balancer (ILB)** reference module, stack, and comparison doc are **archived** under [**`archive/`**](archive/README.md) (not maintained as a first-class path here).

**Historical comparison (ILB vs BGP):** [archive/ILB-vs-BGP.md](archive/ILB-vs-BGP.md)

---

## Problem (one minute)

KubeVirt / migration scenarios often need:

- **Preserved pod/VM IPs** and **direct routing** from the VPC (or peered networks).
- **Egress without SNAT** to arbitrary external destinations (OVN default SNATs through the node).

This repo wires **GCP** (BGP + NCC) with **OpenShift** so the CUDN overlay is routable and **RouteAdvertisements** narrow SNAT to cluster-internal destinations only.

---

## Shared prerequisites

- **OCM:** `OSDGOOGLE_TOKEN` or `ocm_token`
- **GCP:** project with OSD entitlements; **`gcloud auth application-default login`**
- **WIF:** same `cluster_name` and `gcp_project_id` as **`wif_config/`** (the **`bgp.run`** script applies **`wif_config/`** for you)
- **CLI:** `terraform`, `gcloud`, `oc`, `jq`. BGP **`configure-routing.sh`** needs only **`oc`**. **`make controller.run`** / **`controller.watch`** read **`terraform output`** from **`cluster_bgp_routing/`**, so apply that stack first and keep state available.

**Terraform inputs (minimum before `make bgp.run`, `make apply`, or `make bgp.apply`):**

Set at least **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`** (they must match **`wif_config`**). Example:

```bash
export TF_VAR_gcp_project_id="my-gcp-project"
export TF_VAR_cluster_name="my-cluster-name"
```

Alternatively, copy [**`cluster_bgp_routing/terraform.tfvars.example`**](cluster_bgp_routing/terraform.tfvars.example) to **`terraform.tfvars`** in **`cluster_bgp_routing/`** and set **`gcp_project_id`** / **`cluster_name`** there (plus any other variables you need). Use the **`.example`** file as the checklist for optional settings (region, node counts, feature flags, etc.). **Remote state:** [docs/terraform-backend-gcs.md](docs/terraform-backend-gcs.md) and **`cluster_bgp_routing/backend.tf.example`**.

**IAM:** extra roles for NCC / Cloud Router on the identity running `terraform apply` — [archive/ILB-vs-BGP.md § Additional IAM requirements](archive/ILB-vs-BGP.md#additional-iam-requirements).

---

## Quick start — BGP

Use **GCP credentials** and **Terraform inputs** as above (**BGP IAM** for the principal running `terraform apply` — [archive/ILB-vs-BGP.md § IAM](archive/ILB-vs-BGP.md#additional-iam-requirements)), plus [`cluster_bgp_routing/terraform.tfvars.example`](cluster_bgp_routing/terraform.tfvars.example) if you prefer a tfvars file.

From the **repository root**, the reference path is **fully scripted** (no hand-edited manifests or copy-paste from terraform output):

```bash
export TF_VAR_gcp_project_id="my-gcp-project"
export TF_VAR_cluster_name="my-cluster-name"
```

> Note: the controller can take some time to reconcile the resources, enable ip forwarding and set up BGP routes.  Be patient.  Similarily the e2e tests can take some time for the routes for a pod to be advertised, if the e2e script fails, wait a minute and try again.

```bash
make bgp.run
make bgp.deploy-controller
make bgp.e2e
```

1. **`make bgp.run`** — **`wif_config/`** → **`cluster_bgp_routing/`** (static NCC hub, Cloud Router, echo VM), **`oc login`**, **`configure-routing.sh`** (FRR, CUDN, RouteAdvertisements).

2. **`make bgp.deploy-controller`** — [**`controller_gcp_iam/`**](controller_gcp_iam/README.md) apply, WIF credential **Secret** (**`gcloud`** ADC), **ConfigMap** populated from **`cluster_bgp_routing` `terraform output`**, then namespace / RBAC / ImageStream / BuildConfig / Deployment, **binary image build**, and rollout ([`scripts/bgp-deploy-controller-incluster.sh`](scripts/bgp-deploy-controller-incluster.sh)). Pass **`TF_VARS`** / **`EXTRA_TF_VARS`** through to **`controller_gcp_iam`** the same as **`make bgp.run`**.

3. **`make bgp.e2e`** — CUDN pod ↔ echo VM **`ping`** / **`curl`**. Test pods are scheduled on nodes that have **`node-role.kubernetes.io/bgp-router`** (same label the BGP controller applies). Wait until Cloud Router BGP is **Established** if the first run is flaky. Run the controller (**`make bgp.deploy-controller`**) before e2e so workers are labeled and peered.

**Alternative (workstation operator):** after **`make bgp.run`**, use **`make controller.venv`** and **`make controller.run`** (or **`controller.watch`**) with ADC instead of **`make bgp.deploy-controller`** — see [controller/python/README.md](controller/python/README.md).

Troubleshooting: [cluster_bgp_routing § Quick start (pod and echo VM)](cluster_bgp_routing/README.md#quick-start-pod-and-echo-vm), **`cluster_bgp_routing/scripts/debug-gcp-bgp.sh`**.

**RouteAdvertisements / BGP baseline (no cluster changes):** **`make bgp.phase1-baseline`** — [references/fix-bgp-ra.md](references/fix-bgp-ra.md) Phase 1 (router-labeled nodes, RA **`nodeSelector`**, FRR CRs, then **`debug-gcp-bgp.sh`**).

**When you are done**, remove controller-managed GCP state, then tear down — [cluster_bgp_routing § Teardown](cluster_bgp_routing/README.md#teardown).

```bash
make controller.cleanup   # removes in-cluster Deployment (if any), then peers / all numbered NCC spokes / FRR / labels
make bgp.teardown
```

More detail: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

---

## Makefile targets (summary)

Convention: **`stack.action`** separated by dots; multi-word segments use hyphens (for example **`controller.gcp-iam.init`**, **`controller.deploy-openshift`**). End-to-end orchestration uses **`bgp.run`** (not **`bgp.apply`**, which is Terraform-only for **`cluster_bgp_routing/`**).

| Target | Directory / action |
|--------|-------------------|
| `bgp.run` / `bgp.teardown` | Full BGP deploy / destroy `cluster_bgp_routing` then `wif_config` (`bgp.teardown` does **not** run **`controller.cleanup`**) |
| `bgp.deploy-controller` | After **`bgp.run`**: controller IAM, WIF Secret, ConfigMap from TF output, in-cluster build + rollout |
| `controller.venv` / `controller.run` / `controller.watch` | BGP controller Python venv, one-shot reconcile, long-lived operator — see [controller/python/README.md](controller/python/README.md) |
| `controller.cleanup` / `controller.build` / `controller.deploy-openshift` | Teardown (Deployment + peers/spoke/FRR/labels) / local podman build / OpenShift apply + binary build + rollout |
| `controller.gcp-iam.*` / `controller.gcp-credentials` | BGP controller GCP SA + WIF IAM ([`controller_gcp_iam/`](controller_gcp_iam/README.md)) / generate `credential-config.json` ([`scripts/bgp-controller-gcp-credentials.sh`](scripts/bgp-controller-gcp-credentials.sh)) |
| `bgp.e2e` | Run [`scripts/e2e-cudn-connectivity.sh`](scripts/e2e-cudn-connectivity.sh) against **`cluster_bgp_routing/`** |
| `bgp.phase1-baseline` | [`scripts/bgp-phase1-baseline.sh`](scripts/bgp-phase1-baseline.sh) — Phase 1 in [references/fix-bgp-ra.md](references/fix-bgp-ra.md) |
| `init`, `plan`, `apply`, `destroy` | **`cluster_bgp_routing/`** (same root as **`bgp.init`** / **`bgp.apply`**) |
| `bgp.init`, `bgp.plan`, `bgp.apply` | **`cluster_bgp_routing/`** Terraform only (use **`make bgp.teardown`** for full stack teardown) |
| `wif.*` | **`wif_config/`** |
| `fmt`, `validate` | WIF, **`modules/*`**, **`cluster_bgp_routing`**, **`controller_gcp_iam`** |

Terraform extras: `TF_VARS`, `EXTRA_TF_VARS`. Env vars for apply scripts: [scripts/README.md](scripts/README.md).

**Archived ILB:** scripts under **`archive/scripts/`** — see [**archive/README.md**](archive/README.md).

---

## Repository layout

```text
wif_config/                 # WIF — apply first
controller_gcp_iam/        # BGP controller GCP SA + WIF bind (after WIF in OCM)
modules/osd-bgp-routing/    # Reusable BGP (NCC + Cloud Router) module
modules/osd-bgp-controller-iam/ # Controller GCP custom role + SA + WIF (used by controller_gcp_iam/)
cluster_bgp_routing/        # BGP reference root + scripts/ + PRODUCTION-ROADMAP.md
scripts/                    # bgp-apply.sh, bgp-deploy-controller-incluster.sh, e2e, …
archive/                    # Archived ILB module, cluster_ilb_routing, ILB-vs-BGP.md, ilb-*.sh
```

---

## Roadmap / TODO

- **BGP — dedicated routing nodes:** Today the reference stack registers **worker** VMs as NCC Router Appliance instances and peers BGP from Cloud Router to each. A future direction is **separate node pool / machines** (or non-schedulable nodes) used only for forwarding and BGP, so cluster scaling and worker replacement do not directly imply NCC spoke and peer churn. (No implementation or timeline here — tracking intent only.)

---

## More documentation

| Doc | Purpose |
|-----|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Definitive architecture: data plane, control plane, GCP + OpenShift components, design decisions |
| [KNOWLEDGE.md](KNOWLEDGE.md) | Verified facts and unverified assumptions about CUDN BGP routing |
| [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md) | BGP deployment, IAM, variables, verification, teardown |
| [archive/README.md](archive/README.md) | Archived ILB layout and how to run **`archive/scripts/ilb-*.sh`** |
| [archive/ILB-vs-BGP.md](archive/ILB-vs-BGP.md) | Historical side-by-side comparison with ILB |
| [PRODUCTION.md](PRODUCTION.md) | Production readiness (BGP stack + roadmap links); phased checklist in [cluster_bgp_routing/PRODUCTION-ROADMAP.md](cluster_bgp_routing/PRODUCTION-ROADMAP.md) |
| [wif_config/README.md](wif_config/README.md) | WIF apply order and variables |
| [controller_gcp_iam/README.md](controller_gcp_iam/README.md) | BGP controller GCP IAM + credential JSON workflow |
| [modules/osd-bgp-routing/README.md](modules/osd-bgp-routing/README.md) | Consume BGP module from another root |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

PRs: run **`make fmt`** before submission.
