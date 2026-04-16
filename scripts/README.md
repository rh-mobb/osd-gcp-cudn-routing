# Repository scripts

## End-to-end orchestration

| Script | Purpose |
|--------|---------|
| [`bgp-apply.sh`](bgp-apply.sh) | WIF apply → `cluster_bgp_routing` single apply (static infra + echo VM) → `oc login` → `configure-routing.sh` (one-time setup). Dynamic resources (NCC spoke, BGP peers, canIpForward, FRRConfiguration) are managed by the operator. Invoked by **`make bgp.run`**. |
| [`bgp-destroy.sh`](bgp-destroy.sh) | Destroy **`cluster_bgp_routing/`** then **`wif_config/`**. Invoked by **`make bgp.teardown`** (second step of **`make destroy`**). Run **`make bgp.destroy-operator`** first if you used **`make bgp.deploy-operator`** but are not using **`make destroy`** (deletes `BGPRoutingConfig` via finalizer, operator resources, CRDs, and **`controller_gcp_iam/`**). |
| [`bgp-deploy-operator-incluster.sh`](bgp-deploy-operator-incluster.sh) | After **`make bgp.run`**: **`controller_gcp_iam`** apply, WIF credential Secret, CRDs from **`operator/config/crd/bases/`**, **`operator/deploy/`** RBAC, **`BGPRoutingConfig`** `cluster` from Terraform outputs, ImageStream + BuildConfig + **`oc start-build`** from **`operator/`** (unless **`BGP_OPERATOR_PREBUILT_IMAGE`**), Deployment with WIF volumes. Invoked by **`make bgp.deploy-operator`** / **`make create`** / **`make dev`**. |
| **`make bgp.e2e`** | Run [`e2e-cudn-connectivity.sh`](e2e-cudn-connectivity.sh) with **`-C cluster_bgp_routing/`** (from repo root). After **`make bgp.run`** and **`make bgp.deploy-operator`** (and after BGP-labeled nodes are **Ready** — **`make create`** / **`make dev`** print **`post-operator-deploy-msg`** with **`watch 'oc get nodes -l …'`** instead of running e2e). Requires **`oc`** and **`gcloud`**. |
| **`make bgp.phase1-baseline`** | [references/fix-bgp-ra.md](../references/fix-bgp-ra.md) **Phase 1**: no cluster changes — [`bgp-phase1-baseline.sh`](bgp-phase1-baseline.sh) prints nodes labeled **`routing.osd.redhat.com/bgp-router`**, **`RouteAdvertisements/default`** (**`spec.nodeSelector`**), **`FRRConfiguration`** in **`openshift-frr-k8s`**, then **`cluster_bgp_routing/scripts/debug-gcp-bgp.sh`**. Flags: **`--skip-gcp`**, **`--e2e`**. |

### Archived

The legacy controller deploy script and ILB orchestration scripts live under [**`archive/scripts/`**](../archive/README.md): **`bgp-deploy-controller-incluster.sh`**, **`terraform-controller-env-from-json.sh`**, **`ilb-apply.sh`**, **`ilb-destroy.sh`**. They are not invoked by **`make`** targets on the main branch layout.

### Environment variables

**`bgp-apply.sh`**

| Variable | Default | Meaning |
|----------|---------|---------|
| `OC_LOGIN_EXTRA_ARGS` | **`--insecure-skip-tls-verify`** (when unset) | Extra args to **`oc login`**. If unset, defaults to **`--insecure-skip-tls-verify`** (skips the API TLS wait below). If **`--insecure-skip-tls-verify`** appears in the value, the wait is skipped. To poll until TLS verifies with system CAs instead, **`export OC_LOGIN_EXTRA_ARGS=`** (empty but set) before **`make bgp.run`**. |
| `OC_WAIT_API_TLS_MAX_SEC` | `600` | Before **`oc login`**, poll **`/version`** until TLS verifies with system CAs (OCM replacing bootstrap cert); max seconds. |
| `OC_WAIT_API_TLS_INTERVAL_SEC` | `15` | Seconds between TLS probes. |

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

## OpenShift Virtualization + RWX storage

| Script | Purpose |
|--------|---------|
| [`destroy-openshift-virt-storage.sh`](destroy-openshift-virt-storage.sh) | Before cluster teardown: remove **os-images** CDI importers (**DataImportCron** / **DataVolume**), **VolumeSnapshots**, **PVCs** on **`sp-balanced-storage`** (wait **`VIRT_DESTROY_WAIT_SEC`**); then **VolumeSnapshotClass** **`csi-gce-pd-vsc-images`**, **StorageClass** **`sp-balanced-storage`**, restore **`standard-csi`** default; then **GCP disks** still in the pool and **`STORAGE_POOL_NAME`** pool per zone from **`availability_zones`**. **`make virt.destroy-storage`**. Env: **`SKIP_GCP_POOLS=1`**, **`SKIP_CLUSTER_STORAGE=1`**, **`OS_IMAGES_NS`**, **`VIRT_DESTROY_WAIT_SEC`**. Does **not** remove **`openshift-cnv`** / CNV. |
| [`deploy-openshift-virt.sh`](deploy-openshift-virt.sh) | **Preflight:** validates GCP Hyperdisk pool sizing (capacity / IOPS / throughput vs [pool limits](https://cloud.google.com/compute/docs/disks/storage-pools#pool-limits)), **`oc apply --dry-run=client`** for **StorageClass** + CNV OLM + **HyperConverged**, and **`curl`** HEAD on the VolumeSnapshotClass URL. **CNV:** creates **OperatorGroup** only if the namespace has none (avoids **TooManyOperatorGroups** vs OperatorHub **`openshift-cnv-*`**); fails if **two+** **OperatorGroups** exist. **Then:** pool (**`gcloud compute storage-pools create`**), **StorageClass**, **`standard-csi`**, **VolumeSnapshotClass**, OLM, **HyperConverged**, verify. Reads **`gcp_project_id`**, **`gcp_region`**, **`availability_zones`** from **`cluster_bgp_routing/`**. **`make virt.deploy`**. Storage: [gcp-storage-configuration-4.21](https://github.com/noamasu/docs/blob/main/gcp/gcp-storage-configuration-4.21.md). |

| Variable | Default | Meaning |
|----------|---------|---------|
| `STORAGE_POOL_NAME` | `ocp-virt-pool` | Name of the GCP Hyperdisk storage pool (created if absent). |
| `STORAGE_POOL_PROVISIONED_CAPACITY` | `10240GiB` | **`gcloud --provisioned-capacity`** (minimum **10240 GiB** / **10 TiB** for Hyperdisk Balanced; **`10TiB`** is also accepted). |
| `STORAGE_POOL_CAPACITY_GB` | _(unset)_ | Deprecated: if set and **`STORAGE_POOL_PROVISIONED_CAPACITY`** is unset, uses **`${STORAGE_POOL_CAPACITY_GB}GiB`** (e.g. **10240** → **10 TiB**). |
| `STORAGE_POOL_PROVISIONED_IOPS` | `10000` | Pool IOPS; must be a multiple of **10000** ([GCP](https://cloud.google.com/compute/docs/disks/storage-pools#pool-limits)). |
| `STORAGE_POOL_PROVISIONED_THROUGHPUT` | `1024` | Pool throughput in **MiB/s**; minimum **1024** (1 GiB/s); multiples of **1024**. |
| `CNV_CHANNEL` | `stable` | OLM channel (matches [OCP 4.21 virtualization install](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/installing) and OperatorHub). |
| `CNV_SUBSCRIPTION_NAME` | `hco-operatorhub` | **`Subscription.metadata.name`** — must match OperatorHub (not `kubevirt-hyperconverged`). |
| `CNV_PACKAGE_NAME` | `kubevirt-hyperconverged` | **`Subscription.spec.name`** (catalog package). |
| `CNV_STARTING_CSV` | _(unset)_ | Optional **`spec.startingCSV`** pin (doc example: `kubevirt-hyperconverged-operator.v4.21.3`). |
| `SKIP_STORAGE` | _(unset)_ | Set to **`1`** to skip Hyperdisk StorageClass and VolumeSnapshotClass setup. |
| `CNV_WAIT_TIMEOUT` | `600s` | Timeout for CSV / HyperConverged readiness waits. |
| `CNV_WAIT_DIAG_INTERVAL_SEC` | `30` | While waiting for the CSV to appear, print subscription / installplan / CSV snapshot every **N** seconds. |

## CUDN connectivity (BGP stack)

| Script | Purpose |
|--------|---------|
| [`deploy-cudn-test-pods.sh`](deploy-cudn-test-pods.sh) | **`netshoot-cudn`** + **`icanhazip-cudn`**; **`oc wait`** for Ready. No **nodeAffinity** on router labels (all workers are BGP peers in the reference stack). By default **does not delete** existing pods (stable CUDN IPs / faster e2e); use **`--recreate-test-pods`** or **`CUDN_TEST_PODS_RECREATE=1`** when pods must be replaced (immutable spec). |
| [`e2e-cudn-connectivity.sh`](e2e-cudn-connectivity.sh) | Runs **`deploy-cudn-test-pods.sh`**, then **pod → echo VM** (`ping`, `curl` with body = netshoot CUDN IP) and **echo VM → pod** (`ping`, `curl` **`icanhazip`** with body = VM IP). Connectivity steps **1–3 always run**; failures are printed and **`exit 1`** only after the **Summary** if any step failed. HTTP probes retry (**default 12** attempts, **10s** connect / **25s** max per attempt, **3s** sleep); override with **`CUDN_E2E_HTTP_CURL_ATTEMPTS`**, **`CUDN_E2E_HTTP_CONNECT_TIMEOUT`**, **`CUDN_E2E_HTTP_MAX_TIME`**, **`CUDN_E2E_HTTP_RETRY_SLEEP`**. **`--recreate-test-pods`** / **`CUDN_E2E_RECREATE_TEST_PODS=1`** forwards to deploy (optional pod delete). Echo VM SSH uses **`gcloud compute ssh --tunnel-through-iap`**. Requires **`gcloud`**, **`jq`**, **`terraform`** outputs **`echo_client_*`**. **Env:** **`NO_COLOR=1`** disables colors; **`FORCE_COLOR=1`** forces colors if stderr is not a TTY. |

## GCP WIF custom roles — soft delete recovery

Deleting project custom IAM roles (for example during **`wif.destroy`** / stack teardown) leaves them **soft-deleted** in GCP for a retention period. **`terraform apply`** can then fail with **`role_id (...) which has been marked for deletion, failedPrecondition`**.

**Terraform provider:** There is **no** dedicated "undelete" resource. **`google_project_iam_custom_role`** documents a read-only **`deleted`** attribute ([registry](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_iam_custom_role)); you cannot set **`deleted = false`** to force undelete. The provider may reconcile **within the recoverable window** when it can still see the soft-deleted role; behavior and timing are tracked in issues such as [terraform-provider-google#9066](https://github.com/hashicorp/terraform-provider-google/issues/9066). Outside that window, **`apply`** may keep failing until GCP releases the **`role_id`** or you use new ids (if the platform allows).

**Finding roles with `gcloud` (before relying on the script):**

1. **Counts:** `gcloud iam roles list --project=PROJECT_ID --format='value(name)' | wc -l` and the same with **`--show-deleted`**. If the counts are **equal**, soft-deleted roles are **not** exposed as extra rows in list output (common once roles have left the recoverable list state).
2. **Inspect one id:** `gcloud iam roles describe ROLE_ID --project=PROJECT_ID` — **`NOT_FOUND`** means the role is not visible as an active resource.
3. **Try undelete:** `gcloud iam roles undelete ROLE_ID --project=PROJECT_ID` — if this returns **`NOT_FOUND`** while **`apply`** still says **marked for deletion**, the **`role_id`** is in GCP's **reserved / tombstone** phase: **not** listable and **not** recoverable with **`undelete`**; you typically **wait** until Google allows reusing that id (published timelines vary; often on the order of **weeks**) or change **`role_id`**s if OSD/WIF allows.

| Script / Make | Purpose |
|---------------|---------|
| [`gcp-undelete-wif-custom-roles.sh`](gcp-undelete-wif-custom-roles.sh) | **Default (no args):** runs **`terraform`** in **`wif_config/`** (override with **`--terraform-dir`** or env **`WIF_UNDELETE_TERRAFORM_DIR`**) to read **`var.gcp_project_id`** and the same **WIF role prefix** rule as **`osd-wif-config`** (**`coalesce(var.role_prefix, cluster_name with `-` / `_` removed)`**), then compares **`gcloud iam roles list`** with and without **`--show-deleted`** (**`value(name)`**) to find **`role_id`** values that appear **only** with **`--show-deleted`**, then runs **`gcloud iam roles undelete`**. This only finds roles **while** GCP still lists them that way; it cannot fix tombstoned ids (see above). Optional **`--no-prefix-filter`**, explicit **`PROJECT_ID ROLE_ID …`**, or **`--from-log PATH`**. Flags: **`--dry-run`**, **`--continue-on-error`**. Requires **`gcloud`**, **`terraform`**, and IAM permission to list/undelete roles. |
| **`make wif.undelete-soft-deleted-roles`** | Runs the script; **`WIF_UNDELETE_ARGS`** is optional (for example **`--dry-run`**, **`--from-log ./apply.log`**, **`--terraform-dir ./path`**, **`--no-prefix-filter`**). With no extra args, discovery uses repo **`wif_config/`** and your **`terraform.tfvars`** / **`TF_VAR_*`**. After a successful undelete, align Terraform state (often per-resource **`terraform import`** for **`google_project_iam_custom_role`** under **`module.wif_gcp`**). |

## GCP credentials

| Script | Purpose |
|--------|---------|
| [`bgp-controller-gcp-credentials.sh`](bgp-controller-gcp-credentials.sh) | After **`controller_gcp_iam/`** Terraform apply: runs **`gcloud iam workload-identity-pools create-cred-config`** using **`terraform output`** (pool path + service account). Optional **`--apply-secret`** / **`CONTROLLER_GCP_CRED_APPLY_SECRET=1`** to update OpenShift Secret **`bgp-routing-gcp-credentials`**. Invoked by **`make iam.credentials`**; **`bgp-deploy-operator-incluster.sh`** sets **`CONTROLLER_GCP_CRED_APPLY_SECRET=1`**. |

## Related scripts

- **`orchestration-lib.sh`** — helpers sourced by **`bgp-apply.sh`** and archived **`ilb-apply.sh`** (Terraform state probe for pass-1 skip).
- **Archived:** [**`archive/`**](../archive/README.md) — ILB stack (**`cluster_ilb_routing/`**, **`archive/scripts/ilb-*.sh`**), legacy controllers (**`archive/controller/go/`**, **`archive/controller/python/`**), and **`archive/scripts/bgp-deploy-controller-incluster.sh`**.
- **BGP stack:** [`cluster_bgp_routing/scripts/`](../cluster_bgp_routing/README.md) — **`configure-routing`** (one-time setup), **`cudn-pod-ip`**, etc.; **`deploy-cudn-test-pods`** is shared via `../scripts`. Includes **`debug-gcp-bgp.sh`** for **`gcloud`** / Cloud Router / NCC checks after apply.
