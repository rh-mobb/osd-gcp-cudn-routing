# OSD GCP CUDN Routing (BGP)

**Experimental** — maintained by the **Red Hat Managed OpenShift Black Belt** team; **not** a supported product or production-ready baseline. See [PRODUCTION.md](PRODUCTION.md) for gaps and automation direction.

This repo provides **Terraform** and scripts to run **OpenShift Dedicated on GCP** with a **Cluster User-Defined Network (CUDN)** so pod and KubeVirt VM IPs are **reachable from the VPC without SNAT** on egress to external destinations. **`cluster_bgp_routing/`** composes **hub + spoke VPCs** ([`modules/osd-hub-vpc`](modules/osd-hub-vpc/), [`modules/osd-spoke-vpc`](modules/osd-spoke-vpc/)) with **`osd-cluster`** from [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google); the **`osdgoogle`** provider is **`~> 0.1.3`** on the [Terraform Registry](https://registry.terraform.io/providers/rh-mobb/osd-google). **`make bgp.run`** applies [**`wif_config/`**](wif_config/README.md) first; expert **`terraform apply`** from **`cluster_bgp_routing/`** alone still expects WIF to exist in OCM.

**BGP reference stack:** **NCC** Router Appliance + **Cloud Router** BGP to **all non-infra worker nodes**. **Terraform** manages static infrastructure (NCC hub, Cloud Router, firewalls). The [**operator**](operator/README.md) (`routing.osd.redhat.com/v1alpha1` CRDs — `BGPRoutingConfig` and `BGPRouter`) reconciles **dynamic** resources: NCC spokes, Cloud Router BGP peers, `canIpForward`, nested virtualization, and per-node `FRRConfiguration` CRs. It labels nodes **`routing.osd.redhat.com/bgp-router`** and reports per-node health via `BGPRouter` status objects. Full guide: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

**Prebuilt operator image (CI):** on each push to **`main`**, [`.github/workflows/publish-operator-image.yml`](.github/workflows/publish-operator-image.yml) publishes **`ghcr.io/<lowercase owner>/<lowercase repo>/bgp-routing-operator`** to **GitHub Container Registry** (tags **`latest`**, **`main`**, **`sha-<commit>`**).

The **internal load balancer (ILB)** reference module, stack, and comparison doc are **archived** under [**`archive/`**](archive/README.md) (not maintained as a first-class path here). The legacy **Go** and **Python** BGP controllers are also archived under [**`archive/controller/`**](archive/README.md) — replaced by the operator.

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
- **CLI:** `terraform`, `gcloud`, `oc`, `jq`. BGP **`configure-routing.sh`** needs only **`oc`**.

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

For the **full manual procedure** (every `terraform` / `oc` / `bash` step, **no Makefile**), see [**docs/bgp-manual-provision-and-teardown.md**](docs/bgp-manual-provision-and-teardown.md).

Use **GCP credentials** and **Terraform inputs** as above (**BGP IAM** for the principal running `terraform apply` — [archive/ILB-vs-BGP.md § IAM](archive/ILB-vs-BGP.md#additional-iam-requirements)), plus [`cluster_bgp_routing/terraform.tfvars.example`](cluster_bgp_routing/terraform.tfvars.example) if you prefer a tfvars file.

From the **repository root**, the reference path is **fully scripted** (no hand-edited manifests or copy-paste from terraform output):

```bash
export TF_VAR_gcp_project_id="my-gcp-project"
export TF_VAR_cluster_name="my-cluster-name"
```

> Note: the operator can take some time to reconcile the resources, enable IP forwarding, and set up BGP routes. Be patient. Similarly the e2e tests can take some time for the routes for a pod to be advertised; if the e2e script fails, wait a minute and try again.

```bash
make create
```

**`make create`** runs **`bgp.run`** then **`bgp.deploy-operator`** (same idea as the former scripted quick start, without auto-running e2e):

1. **`make bgp.run`** — **`wif_config/`** → **`cluster_bgp_routing/`** (hub + spoke VPCs, peering, **`0/0` → hub NAT ILB**, static NCC hub, Cloud Router in **spoke**, optional echo VM), **`oc login`**, **`configure-routing.sh`** (FRR, CUDN, RouteAdvertisements).

2. **`make bgp.deploy-operator`** — [**`controller_gcp_iam/`**](controller_gcp_iam/README.md) apply, WIF credential **Secret** (**`gcloud`** ADC), CRDs, operator RBAC, **`BGPRoutingConfig`** populated from **`cluster_bgp_routing` `terraform output`**, then Deployment and rollout ([`scripts/bgp-deploy-operator-incluster.sh`](scripts/bgp-deploy-operator-incluster.sh)). **`create`** passes **`BGP_OPERATOR_PREBUILT_IMAGE`** so the cluster pulls the published operator from **GHCR** (**`ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-routing-operator:latest`** by default; override with **`CREATE_OPERATOR_IMAGE=…`** on the **`make`** line). Private images need a suitable **pull secret** on the deployment namespace. Pass **`TF_VARS`** / **`EXTRA_TF_VARS`** on the **`make`** command line when needed; they are forwarded to **`bgp.run`** / **`bgp.deploy-operator`**.

After **`create`** or **`dev`**, **`make`** prints **`post-operator-deploy-msg`**: **`watch 'oc get nodes -l routing.osd.redhat.com/bgp-router='`** until every listed node shows **STATUS Ready** for your expected BGP worker count (**`watch`** refreshes the full list each tick), then run **`make bgp.e2e`** (CUDN pod ↔ echo VM **`ping`** / **`curl`**). Test pods use the default scheduler (no router **nodeAffinity**; every worker is a BGP peer). Wait until Cloud Router BGP is **Established** if the first run is flaky.

**`make dev`** is the same two steps but runs an **in-cluster binary `oc start-build`** (ImageStream + BuildConfig) instead of the GHCR image — use this when you are iterating on operator code locally.

You can run **`make bgp.run`**, **`make bgp.deploy-operator`**, **`make post-operator-deploy-msg`** (optional reminder), and **`make bgp.e2e`** separately instead of **`make create`** (omit **`BGP_OPERATOR_PREBUILT_IMAGE`** on the **`make`** line to keep the binary build path).

Troubleshooting: [cluster_bgp_routing § Quick start (pod and echo VM)](cluster_bgp_routing/README.md#quick-start-pod-and-echo-vm), **`cluster_bgp_routing/scripts/debug-gcp-bgp.sh`**.

**RouteAdvertisements / BGP baseline (no cluster changes):** **`make bgp.phase1-baseline`** — [references/fix-bgp-ra.md](references/fix-bgp-ra.md) Phase 1 (router-labeled nodes, RA **`nodeSelector`**, FRR CRs, then **`debug-gcp-bgp.sh`**).

**When you are done**, tear down the operator-managed state, IAM stack, then the cluster and WIF — [cluster_bgp_routing § Teardown](cluster_bgp_routing/README.md#teardown).

```bash
make destroy
```

**`make destroy`** runs **`make bgp.destroy-operator`** then **`make bgp.teardown`**. Pass **`TF_VARS`** / **`EXTRA_TF_VARS`** on the **`make`** command line when **`controller_gcp_iam/`** was applied with the same arguments (recursive **`make`** inherits them into **`iam.destroy`**). You can run **`make bgp.destroy-operator`** and **`make bgp.teardown`** separately instead of **`make destroy`**. **`terraform destroy`** from these **`make`** targets uses **`-auto-approve`** (no interactive confirmation). **`make destroy`**, **`make bgp.destroy-operator`**, and **`make bgp.teardown`** print phase/step banners before each sub-action.

More detail: [**cluster_bgp_routing/README.md**](cluster_bgp_routing/README.md).

---

## Makefile targets (summary)

Convention: **`stack.action`** separated by dots; multi-word segments use hyphens (for example **`iam.init`**, **`bgp.deploy-operator`**). **`make create`** / **`make dev`** / **`make destroy`** wrap the [quick start](#quick-start--bgp). **`bgp.apply`** is Terraform-only for **`cluster_bgp_routing/`** (unlike **`bgp.run`**, which includes WIF, **`oc login`**, and **`configure-routing.sh`**).

| Target | Directory / action |
|--------|-------------------|
| `create` / `dev` / `destroy` | **`create`**: **`bgp.run`** + **`bgp.deploy-operator`** (GHCR operator image), then **`post-operator-deploy-msg`**. **`dev`**: same with in-cluster binary build instead of GHCR. **`destroy`**: **`bgp.destroy-operator`** + **`bgp.teardown`**. |
| `bgp.run` / `bgp.teardown` | Full BGP deploy / destroy `cluster_bgp_routing` then `wif_config` (`bgp.teardown` does **not** remove the operator or **`controller_gcp_iam/`**) |
| `bgp.deploy-operator` | After **`bgp.run`**: IAM + WIF Secret + CRDs + RBAC + **`BGPRoutingConfig`** + operator ImageStream/BuildConfig/build/rollout ([`scripts/bgp-deploy-operator-incluster.sh`](scripts/bgp-deploy-operator-incluster.sh)) |
| `bgp.destroy-operator` | Delete **`BGPRoutingConfig`** (finalizer cleanup), operator Deployment + RBAC, CRDs, then **`iam.destroy`** |
| `post-operator-deploy-msg` | Print **`watch 'oc get nodes -l routing.osd.redhat.com/bgp-router='`** and **`make bgp.e2e`** (after deploy) |
| `operator.build` / `operator.test` / `operator.generate` / `operator.manifests` / `operator.docker-build` | Operator — [operator/README.md](operator/README.md) |
| `iam.*` / `iam.credentials` | BGP operator GCP SA + WIF IAM ([`controller_gcp_iam/`](controller_gcp_iam/README.md)) / generate `credential-config.json` ([`scripts/bgp-controller-gcp-credentials.sh`](scripts/bgp-controller-gcp-credentials.sh)) |
| `bgp.e2e` | Run [`scripts/e2e-cudn-connectivity.sh`](scripts/e2e-cudn-connectivity.sh) against **`cluster_bgp_routing/`** |
| `bgp.phase1-baseline` | [`scripts/bgp-phase1-baseline.sh`](scripts/bgp-phase1-baseline.sh) — Phase 1 in [references/fix-bgp-ra.md](references/fix-bgp-ra.md) |
| `init`, `plan`, `apply`, `cluster.destroy` | **`cluster_bgp_routing/`** Terraform only (same root as **`bgp.init`** / **`bgp.apply`**) |
| `bgp.init`, `bgp.plan`, `bgp.apply` | **`cluster_bgp_routing/`** Terraform only (use **`make bgp.teardown`** for full stack teardown) |
| `wif.*` | **`wif_config/`** (plus **`wif.undelete-soft-deleted-roles`** — undeletes soft-deleted WIF custom roles using **`wif_config/`** Terraform + **`gcloud`**; optional **`WIF_UNDELETE_ARGS`**; [scripts/README.md](scripts/README.md)) |
| `fmt`, `validate` | WIF, **`modules/*`**, **`cluster_bgp_routing`**, **`controller_gcp_iam`** |

Terraform extras: `TF_VARS`, `EXTRA_TF_VARS`. Env vars for apply scripts: [scripts/README.md](scripts/README.md). **`cluster_bgp_routing`** defaults to **`create_baremetal_worker_pool = true`** (second pool: **2** bare metal nodes in one AZ; set **`false`** to skip).

**Archived (ILB + legacy controllers):** see [**archive/README.md**](archive/README.md).

---

## Repository layout

```text
wif_config/                 # WIF — apply first
controller_gcp_iam/         # BGP operator GCP SA + WIF bind (after WIF in OCM)
modules/osd-bgp-routing/    # Reusable BGP (NCC + Cloud Router) module
modules/osd-bgp-controller-iam/ # Operator GCP custom role + SA + WIF (used by controller_gcp_iam/)
cluster_bgp_routing/        # BGP reference root + scripts/ + PRODUCTION-ROADMAP.md
operator/                   # CRD-based operator (BGPRoutingConfig + BGPRouter)
scripts/                    # bgp-apply.sh, bgp-deploy-operator-incluster.sh, e2e, …
archive/                    # Archived: ILB module/stack, legacy Go + Python controllers, ILB-vs-BGP.md
```

---

## Roadmap / TODO

- **BGP — dedicated routing nodes:** Today the reference stack registers **worker** VMs as NCC Router Appliance instances and peers BGP from Cloud Router to each. A future direction is **separate node pool / machines** (or non-schedulable nodes) used only for forwarding and BGP, so cluster scaling and worker replacement do not directly imply NCC spoke and peer churn. (No implementation or timeline here — tracking intent only.)

---

## More documentation

| Doc | Purpose |
|-----|---------|
| [docs/bgp-manual-provision-and-teardown.md](docs/bgp-manual-provision-and-teardown.md) | Full **manual** BGP provision and teardown (`terraform`, `oc`, scripts only — same workflow as the quick start) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Definitive architecture: data plane, control plane, GCP + OpenShift components, design decisions |
| [KNOWLEDGE.md](KNOWLEDGE.md) | Verified facts and unverified assumptions about CUDN BGP routing |
| [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md) | BGP deployment, IAM, variables, verification, teardown |
| [archive/README.md](archive/README.md) | Archived ILB layout, legacy controllers, and how to run archived scripts |
| [archive/ILB-vs-BGP.md](archive/ILB-vs-BGP.md) | Historical side-by-side comparison with ILB |
| [PRODUCTION.md](PRODUCTION.md) | Production readiness (BGP stack + roadmap links); phased checklist in [cluster_bgp_routing/PRODUCTION-ROADMAP.md](cluster_bgp_routing/PRODUCTION-ROADMAP.md) |
| [wif_config/README.md](wif_config/README.md) | WIF apply order and variables |
| [controller_gcp_iam/README.md](controller_gcp_iam/README.md) | BGP operator GCP IAM + credential JSON workflow |
| [modules/osd-bgp-routing/README.md](modules/osd-bgp-routing/README.md) | Consume BGP module from another root |
| [operator/README.md](operator/README.md) | CRD-based operator: BGPRoutingConfig + BGPRouter |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |
| [references/RFE-osd-google-wif-gcp-iam-lifecycle.md](references/RFE-osd-google-wif-gcp-iam-lifecycle.md) | RFE: WIF GCP IAM custom role lifecycle / soft teardown (**osd-google** modules and provider) |

PRs: run **`make fmt`** before submission.
