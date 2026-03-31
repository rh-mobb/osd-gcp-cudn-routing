# Repository scripts

## End-to-end orchestration

| Script | Purpose |
|--------|---------|
| [`bgp-apply.sh`](bgp-apply.sh) | WIF apply → `cluster_bgp_routing` single apply (static infra + echo VM) → `oc login` → `configure-routing.sh` (one-time setup). Dynamic resources (NCC spoke, BGP peers, canIpForward, FRRConfiguration) are managed by the controller. Invoked by **`make bgp.run`**. |
| [`bgp-destroy.sh`](bgp-destroy.sh) | Destroy **`cluster_bgp_routing/`** then **`wif_config/`**. Invoked by **`make bgp.teardown`**. Run **`make controller.cleanup`** first if the BGP controller created peers / spoke / FRR CRs. |
| [`bgp-deploy-controller-incluster.sh`](bgp-deploy-controller-incluster.sh) | After **`make bgp.run`**: **`controller_gcp_iam`** apply, WIF credential Secret, ConfigMap from **`cluster_bgp_routing`** outputs, OpenShift manifests (no **`deploy/configmap.yaml`**), binary build, rollout. Invoked by **`make bgp.deploy-controller`**. |
| **`make bgp.e2e`** | Run [`e2e-cudn-connectivity.sh`](e2e-cudn-connectivity.sh) with **`-C cluster_bgp_routing/`** (from repo root). After **`make bgp.run`** (and **`make bgp.deploy-controller`** if testing the in-cluster operator), with **`oc`** and **`gcloud`** working. |
| **`make bgp.phase1-baseline`** | [references/fix-bgp-ra.md](../references/fix-bgp-ra.md) **Phase 1**: no cluster changes — [`bgp-phase1-baseline.sh`](bgp-phase1-baseline.sh) prints **`node-role.kubernetes.io/bgp-router`** nodes, **`RouteAdvertisements/default`** (**`spec.nodeSelector`**), **`FRRConfiguration`** in **`openshift-frr-k8s`**, then **`cluster_bgp_routing/scripts/debug-gcp-bgp.sh`**. Flags: **`--skip-gcp`**, **`--e2e`**. |

### Archived (ILB)

The ILB orchestration scripts live under [**`archive/scripts/`**](../archive/README.md): **`ilb-apply.sh`**, **`ilb-destroy.sh`**. They are not invoked by **`make`** targets on the main branch layout.

### Environment variables

**`bgp-apply.sh`**

| Variable | Default | Meaning |
|----------|---------|---------|
| `OC_LOGIN_EXTRA_ARGS` | _(empty)_ | Extra args to `oc login` (e.g. `--insecure-skip-tls-verify`) |

**Archived `ilb-apply.sh`** (see [**archive/README.md**](../archive/README.md))

| Variable | Default | Meaning |
|----------|---------|---------|
| `ILB_APPLY_WORKER_WAIT_ATTEMPTS` | `60` | Max polls for running `*-worker-*` VMs before failing |
| `ILB_APPLY_WORKER_WAIT_SLEEP` | `30` | Seconds between polls |
| `ILB_APPLY_MIN_WORKERS` | `1` | Minimum worker count required to proceed |
| `OC_LOGIN_EXTRA_ARGS` | _(empty)_ | Extra args to `oc login` |

**`bgp-apply.sh`** / **archived `ilb-apply.sh`** (shared library)

| Variable | Default | Meaning |
|----------|---------|--------|
| `ORCHESTRATION_FORCE_PASS1` | _(unset)_ | If **`1`** or **`true`**, always run pass-1 cluster **`terraform apply`** where applicable (routing flags default **off**). By default, pass 1 is **skipped** when **`module.bgp_routing[0]`** (BGP) or **`module.ilb_routing[0]`** (archived ILB) is already in state. |

Terraform arguments: pass through **`make bgp.run`** as `TF_VARS="-var-file=…"` or `EXTRA_TF_VARS="-var=key=value"` (see root `Makefile`); apply scripts forward **`"$@"`** to **`terraform apply`**. You still need cluster inputs (at minimum **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`**, or a **`terraform.tfvars`** — [root README § Shared prerequisites](../README.md#shared-prerequisites)).

## CUDN connectivity (BGP stack)

| Script | Purpose |
|--------|---------|
| [`deploy-cudn-test-pods.sh`](deploy-cudn-test-pods.sh) | **`netshoot-cudn`** + **`icanhazip-cudn`**; **`oc wait`** for Ready. **`--avoid-bgp-router`** or **`CUDN_TEST_PODS_AVOID_BGP_ROUTERS=1`** — **`nodeAffinity`** **`DoesNotExist`** **`node-role.kubernetes.io/bgp-router`** ([references/fix-bgp-ra.md](../references/fix-bgp-ra.md) Phase 3); deletes existing test pods first so affinity applies. Used by cluster wrappers and **`e2e-cudn-connectivity.sh`**. |
| [`e2e-cudn-connectivity.sh`](e2e-cudn-connectivity.sh) | Runs **`deploy-cudn-test-pods.sh`**, then **pod → echo VM** (`ping`, `curl` with body = netshoot CUDN IP) and **echo VM → pod** (`ping`, `curl` **`icanhazip`** with body = VM IP). **`--avoid-bgp-router`** or **`CUDN_E2E_POD_AVOID_BGP_ROUTERS=1`** enables Phase 3 strict placement + post-schedule check. Echo VM SSH uses **`gcloud compute ssh --tunnel-through-iap`**. Prefer **`make bgp.e2e`** from the repo root, or **`--cluster-dir`**. Requires **`gcloud`**, **`jq`**, **`terraform`** outputs **`echo_client_*`**. **Env:** **`NO_COLOR=1`** disables colors; **`FORCE_COLOR=1`** forces colors if stderr is not a TTY. |

## BGP controller GCP credentials

| Script | Purpose |
|--------|---------|
| [`bgp-controller-gcp-credentials.sh`](bgp-controller-gcp-credentials.sh) | After **`controller_gcp_iam/`** Terraform apply: runs **`gcloud iam workload-identity-pools create-cred-config`** using **`terraform output`** (pool path + service account). Optional **`--apply-secret`** / **`CONTROLLER_GCP_CRED_APPLY_SECRET=1`** to update OpenShift Secret **`bgp-routing-gcp-credentials`**. Invoked by **`make controller.gcp-credentials`**; **`bgp-deploy-controller-incluster.sh`** sets **`CONTROLLER_GCP_CRED_APPLY_SECRET=1`**. |

## Related scripts

- **`orchestration-lib.sh`** — helpers sourced by **`bgp-apply.sh`** and archived **`ilb-apply.sh`** (Terraform state probe for pass-1 skip).
- **Archived ILB stack:** [**`archive/`**](../archive/README.md) — **`cluster_ilb_routing/`**, **`archive/scripts/ilb-*.sh`**.
- **BGP stack:** [`cluster_bgp_routing/scripts/`](../cluster_bgp_routing/README.md) — **`configure-routing`** (one-time setup), **`cudn-pod-ip`**, etc.; **`deploy-cudn-test-pods`** is shared via `../scripts`. Includes **`debug-gcp-bgp.sh`** for **`gcloud`** / Cloud Router / NCC checks after apply.
