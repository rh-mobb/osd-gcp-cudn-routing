# OSD GCP CUDN Routing (BGP)

**Experimental** — maintained by the **Red Hat Managed OpenShift Black Belt** team; **not** a supported product or production-ready baseline. See [PRODUCTION.md](PRODUCTION.md) for gaps and automation direction.

This repo provides **Terraform** and scripts to run **OpenShift Dedicated on GCP** with a **Cluster User-Defined Network (CUDN)** so pod and KubeVirt VM IPs are **reachable from the VPC without SNAT** on egress to external destinations. VPC/cluster modules come from [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google); the **`osdgoogle`** provider is **`~> 0.1.3`** on the [Terraform Registry](https://registry.terraform.io/providers/rh-mobb/osd-google). **`make bgp.run`** applies [**`wif_config/`**](wif_config/README.md) first; expert **`terraform apply`** from **`cluster_bgp_routing/`** alone still expects WIF to exist in OCM.

**Active reference stack — BGP:** **NCC** Router Appliance + **Cloud Router** BGP to **all non-infra worker nodes** (controller labels **`cudn.redhat.com/bgp-router`** and sets **GCP status annotations** on nodes after **`canIpForward`** / nested virt); routes learned into the VPC. **Per-node** `FRRConfiguration`. **Single** `terraform apply` (static infra) plus the [BGP controller (Go)](controller/go/README.md) for spoke, peers, and FRR CRs. The [Python / kopf prototype](controller/python/README.md) remains for reference. Full guide: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

**Prebuilt controller images (CI):** on each push to **`main`**, [`.github/workflows/publish-controller-images.yml`](.github/workflows/publish-controller-images.yml) publishes **`ghcr.io/<lowercase owner>/<lowercase repo>/bgp-controller-go`** and **`…/bgp-controller-python`** to **GitHub Container Registry** (tags **`latest`**, **`main`**, **`sha-<commit>`**).

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

**Terraform inputs (minimum before `make create`, `make bgp.run`, `make apply`, or `make bgp.apply`):**

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
make create
```

**`make create`** runs **`bgp.run`** then **`bgp.deploy-controller`** (same idea as the former scripted quick start, without auto-running e2e):

1. **`make bgp.run`** — **`wif_config/`** → **`cluster_bgp_routing/`** (static NCC hub, Cloud Router, echo VM), **`oc login`**, **`configure-routing.sh`** (FRR, CUDN, RouteAdvertisements).

2. **`make bgp.deploy-controller`** — [**`controller_gcp_iam/`**](controller_gcp_iam/README.md) apply, WIF credential **Secret** (**`gcloud`** ADC), **ConfigMap** populated from **`cluster_bgp_routing` `terraform output`**, then namespace / RBAC / Deployment, and rollout ([`scripts/bgp-deploy-controller-incluster.sh`](scripts/bgp-deploy-controller-incluster.sh)). **`create`** passes **`BGP_CONTROLLER_PREBUILT_IMAGE`** so the cluster pulls the published Go controller from **GHCR** (**`ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-controller-go:latest`** by default; override with **`CREATE_CONTROLLER_IMAGE=…`** on the **`make`** line). Private images need a suitable **pull secret** on the deployment namespace. Pass **`TF_VARS`** / **`EXTRA_TF_VARS`** on the **`make`** command line when needed; they are forwarded to **`bgp.run`** / **`bgp.deploy-controller`**.

After **`create`** or **`dev`**, **`make`** prints **`post-controller-deploy-msg`**: **`watch 'oc get nodes -l cudn.redhat.com/bgp-router='`** until every listed node shows **STATUS Ready** for your expected BGP worker count ( **`watch`** refreshes the full list each tick), then run **`make bgp.e2e`** (CUDN pod ↔ echo VM **`ping`** / **`curl`**). Test pods use the default scheduler (no router **nodeAffinity**; every worker is a BGP peer). Wait until Cloud Router BGP is **Established** if the first run is flaky. If you changed **`ROUTER_LABEL_KEY`** in the controller ConfigMap, adjust the **`-l`** selector to match.

**`make dev`** is the same two steps but runs an **in-cluster binary `oc start-build`** (ImageStream + BuildConfig) instead of the GHCR image — use this when you are iterating on controller code locally.

You can run **`make bgp.run`**, **`make bgp.deploy-controller`**, **`make post-controller-deploy-msg`** (optional reminder), and **`make bgp.e2e`** separately instead of **`make create`** (omit **`BGP_CONTROLLER_PREBUILT_IMAGE`** on the **`make`** line to keep the binary build path).

**Alternative (workstation):** after **`make bgp.run`**, use **`make controller.run`** (one-shot) or **`make controller.watch`** with ADC instead of **`make bgp.deploy-controller`** — see [controller/go/README.md](controller/go/README.md). The Python controller under **`controller/python/`** still supports **`make -C controller/python venv`** for the legacy kopf workflow.

Troubleshooting: [cluster_bgp_routing § Quick start (pod and echo VM)](cluster_bgp_routing/README.md#quick-start-pod-and-echo-vm), **`cluster_bgp_routing/scripts/debug-gcp-bgp.sh`**.

**RouteAdvertisements / BGP baseline (no cluster changes):** **`make bgp.phase1-baseline`** — [references/fix-bgp-ra.md](references/fix-bgp-ra.md) Phase 1 (router-labeled nodes, RA **`nodeSelector`**, FRR CRs, then **`debug-gcp-bgp.sh`**).

**When you are done**, tear down the controller IAM stack, controller-managed state, then the cluster and WIF — [cluster_bgp_routing § Teardown](cluster_bgp_routing/README.md#teardown).

```bash
make destroy
```

**`make destroy`** runs **`make bgp.destroy-controller`** then **`make bgp.teardown`**. Pass **`TF_VARS`** / **`EXTRA_TF_VARS`** on the **`make`** command line when **`controller_gcp_iam/`** was applied with the same arguments (recursive **`make`** inherits them into **`controller.gcp-iam.destroy`**). You can run **`make bgp.destroy-controller`** and **`make bgp.teardown`** separately instead of **`make destroy`**. **`terraform destroy`** from these **`make`** targets uses **`-auto-approve`** (no interactive confirmation). **`make destroy`**, **`make bgp.destroy-controller`**, and **`make bgp.teardown`** print phase/step banners before each sub-action. If **`cluster_bgp_routing`** no longer has Terraform outputs (stack already gone), **`controller.cleanup`** prints a warning and skips **`--cleanup`** so destroy can still run **`controller.gcp-iam.destroy`** and **`bgp.teardown`**.

More detail: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

---

## Makefile targets (summary)

Convention: **`stack.action`** separated by dots; multi-word segments use hyphens (for example **`controller.gcp-iam.init`**, **`controller.deploy-openshift`**). **`make create`** / **`make dev`** / **`make destroy`** wrap the [quick start](#quick-start--bgp). **`bgp.apply`** is Terraform-only for **`cluster_bgp_routing/`** (unlike **`bgp.run`**, which includes WIF, **`oc login`**, and **`configure-routing.sh`**).

| Target | Directory / action |
|--------|-------------------|
| `create` / `dev` / `destroy` | **`create`**: **`bgp.run`** + **`bgp.deploy-controller`** (GHCR Go image), then **`post-controller-deploy-msg`**. **`dev`**: same with in-cluster binary build instead of GHCR. **`destroy`**: **`bgp.destroy-controller`** + **`bgp.teardown`**. |
| `bgp.run` / `bgp.teardown` | Full BGP deploy / destroy `cluster_bgp_routing` then `wif_config` (`bgp.teardown` does **not** remove the controller or **`controller_gcp_iam/`**) |
| `bgp.deploy-controller` | After **`bgp.run`**: controller IAM, WIF Secret, ConfigMap from TF output; **`oc start-build`** unless **`BGP_CONTROLLER_PREBUILT_IMAGE`** is set, then rollout |
| `bgp.destroy-controller` | **`controller.cleanup`** then **`controller.gcp-iam.destroy`** (run before **`bgp.teardown`** when you used the in-cluster controller) |
| `controller.venv` | Python kopf only — [controller/python/README.md](controller/python/README.md) |
| `controller.run` / `controller.watch` / `controller.test` | Go controller — [controller/go/README.md](controller/go/README.md) |
| `controller.cleanup` / `controller.build` / `controller.deploy-openshift` | Teardown (Deployment + peers/spoke/FRR/labels) / local podman build / OpenShift apply + binary build + rollout |
| `controller.gcp-iam.*` / `controller.gcp-credentials` | BGP controller GCP SA + WIF IAM ([`controller_gcp_iam/`](controller_gcp_iam/README.md)) / generate `credential-config.json` ([`scripts/bgp-controller-gcp-credentials.sh`](scripts/bgp-controller-gcp-credentials.sh)) |
| `post-controller-deploy-msg` | Print **`watch 'oc get nodes -l cudn.redhat.com/bgp-router='`** (wait until all listed nodes are **Ready**) and **`make bgp.e2e`** ( **`create`** / **`dev`** invoke this automatically) |
| `bgp.e2e` | Run [`scripts/e2e-cudn-connectivity.sh`](scripts/e2e-cudn-connectivity.sh) against **`cluster_bgp_routing/`** |
| `bgp.phase1-baseline` | [`scripts/bgp-phase1-baseline.sh`](scripts/bgp-phase1-baseline.sh) — Phase 1 in [references/fix-bgp-ra.md](references/fix-bgp-ra.md) |
| `init`, `plan`, `apply`, `cluster.destroy` | **`cluster_bgp_routing/`** Terraform only (same root as **`bgp.init`** / **`bgp.apply`**) |
| `bgp.init`, `bgp.plan`, `bgp.apply` | **`cluster_bgp_routing/`** Terraform only (use **`make bgp.teardown`** for full stack teardown) |
| `wif.*` | **`wif_config/`** (plus **`wif.undelete-soft-deleted-roles`** — undeletes soft-deleted WIF custom roles using **`wif_config/`** Terraform + **`gcloud`**; optional **`WIF_UNDELETE_ARGS`**; [scripts/README.md](scripts/README.md)) |
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
| [references/RFE-osd-google-wif-gcp-iam-lifecycle.md](references/RFE-osd-google-wif-gcp-iam-lifecycle.md) | RFE: WIF GCP IAM custom role lifecycle / soft teardown (**osd-google** modules and provider) |

PRs: run **`make fmt`** before submission.
