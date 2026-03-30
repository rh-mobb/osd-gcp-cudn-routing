# Repository scripts

## End-to-end orchestration

| Script | Purpose |
|--------|---------|
| [`ilb-apply.sh`](ilb-apply.sh) | WIF apply → `cluster_ilb_routing` pass 1 → wait for workers → pass 2 (ILB + echo VM) → `oc login` → `cluster_ilb_routing/scripts/configure-routing.sh`. Invoked by **`make ilb-apply`**. |
| [`ilb-destroy.sh`](ilb-destroy.sh) | `terraform destroy` in `cluster_ilb_routing/`, then `wif_config/`. Invoked by **`make ilb-destroy`**. |
| [`bgp-apply.sh`](bgp-apply.sh) | WIF apply → `cluster_bgp_routing` single apply (static infra + echo VM) → `oc login` → `configure-routing.sh` (one-time setup). Dynamic resources (NCC spoke, BGP peers, canIpForward, FRRConfiguration) are managed by the controller. Invoked by **`make bgp-apply`**. |
| [`bgp-destroy.sh`](bgp-destroy.sh) | Destroy **`cluster_bgp_routing/`** then **`wif_config/`**. Invoked by **`make bgp-destroy`**. |
| **`make ilb-e2e`** / **`make bgp-e2e`** | Run [`e2e-cudn-connectivity.sh`](e2e-cudn-connectivity.sh) with **`-C cluster_ilb_routing/`** or **`-C cluster_bgp_routing/`** (from repo root). After **`make ilb-apply`** / **`make bgp-apply`**, with **`oc`** and **`gcloud`** working. |

### Environment variables

**`ilb-apply.sh`**

| Variable | Default | Meaning |
|----------|---------|---------|
| `ILB_APPLY_WORKER_WAIT_ATTEMPTS` | `60` | Max polls for running `*-worker-*` VMs before failing |
| `ILB_APPLY_WORKER_WAIT_SLEEP` | `30` | Seconds between polls |
| `ILB_APPLY_MIN_WORKERS` | `1` | Minimum worker count required to proceed |
| `OC_LOGIN_EXTRA_ARGS` | _(empty)_ | Extra args to `oc login` (e.g. `--insecure-skip-tls-verify`) |

**`ilb-apply.sh`** / **`bgp-apply.sh`** (shared)

| Variable | Default | Meaning |
|----------|---------|--------|
| `ORCHESTRATION_FORCE_PASS1` | _(unset)_ | If **`1`** or **`true`**, always run pass-1 cluster **`terraform apply`** (routing flags default **off**). By default, pass 1 is **skipped** when **`module.ilb_routing[0]`** / **`module.bgp_routing[0]`** is already in state so a re-run does not tear down pass-2 routing. |

Terraform arguments: pass through **`make ilb-apply`** / **`make bgp-apply`** as `TF_VARS="-var-file=…"` or `EXTRA_TF_VARS="-var=key=value"` (see root `Makefile`). You still need cluster inputs (at minimum **`TF_VAR_gcp_project_id`** and **`TF_VAR_cluster_name`**, or a **`terraform.tfvars`** — [root README § Shared prerequisites](../README.md#shared-prerequisites)).

## CUDN connectivity (ILB or BGP stack)

| Script | Purpose |
|--------|---------|
| [`deploy-cudn-test-pods.sh`](deploy-cudn-test-pods.sh) | **`netshoot-cudn`** + **`icanhazip-cudn`**; **`oc wait`** for Ready. Used by the cluster **`./scripts/deploy-cudn-test-pods.sh`** wrappers and by **`e2e-cudn-connectivity.sh`**. |
| [`e2e-cudn-connectivity.sh`](e2e-cudn-connectivity.sh) | Runs **`deploy-cudn-test-pods.sh`**, then **pod → echo VM** (`ping`, `curl` with body = netshoot CUDN IP) and **echo VM → pod** (`ping`, `curl` **`icanhazip`** with body = VM IP). Echo VM SSH uses **`gcloud compute ssh --tunnel-through-iap`** (IAP API + **`iap.tunnelInstances.accessViaIAP`** / **IAP-secured Tunnel User** on the caller). Prefer **`make ilb-e2e`** / **`make bgp-e2e`** from the repo root, or **`--cluster-dir`**. Requires **`gcloud`**, **`jq`**, **`terraform`** outputs **`echo_client_*`**. **Env:** **`NO_COLOR=1`** disables colors; **`FORCE_COLOR=1`** forces colors if stderr is not a TTY. |

## Related scripts

- **`orchestration-lib.sh`** — helpers sourced by **`ilb-apply.sh`** / **`bgp-apply.sh`** (Terraform state probe for pass-1 skip).
- **ILB stack:** [`cluster_ilb_routing/scripts/`](../cluster_ilb_routing/README.md) — documented in the [root README](../README.md).
- **BGP stack:** [`cluster_bgp_routing/scripts/`](../cluster_bgp_routing/README.md) — **`configure-routing`** (one-time setup), **`cudn-pod-ip`**, etc.; **`deploy-cudn-test-pods`** is shared via `../scripts`. Includes **`debug-gcp-bgp.sh`** for **`gcloud`** / Cloud Router / NCC checks after apply.
