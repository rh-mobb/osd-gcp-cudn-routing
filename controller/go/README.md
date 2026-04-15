# BGP routing controller (Go)

Production-oriented rewrite of the [Python / kopf controller](../python/README.md) using **controller-runtime**. It watches **Nodes**, reconciles **GCP** (NCC spokes, Cloud Router BGP peers, `canIpForward`, nested virtualization by default) and **`FRRConfiguration`** CRs (`frrk8s.metallb.io/v1beta1`) as unstructured objects.

Each Cloud Router neighbor includes **`disableMP: true`** so **OVN-K `RouteAdvertisements`** can merge **`ovnk-generated-*`** configs (MetalLB may log a deprecation warning; omitting the field breaks RA acceptance).

## Configuration

Environment variables match the Python controller (see [deploy/configmap.yaml](deploy/configmap.yaml)).

**Required:** `GCP_PROJECT`, `CLOUD_ROUTER_NAME`, `CLOUD_ROUTER_REGION`, `NCC_HUB_NAME`, `NCC_SPOKE_PREFIX`, `CLUSTER_NAME`.

**Optional:** `FRR_ASN`, `NCC_SPOKE_SITE_TO_SITE`, `ENABLE_GCE_NESTED_VIRTUALIZATION` (defaults **`true`** — GCE nested virt on router VMs via **`instances.update`** with **`RESTART`** when turning it on; **`false`** to skip; not supported on OSD-GCP), `NODE_LABEL_KEY`, `NODE_LABEL_VALUE`, `ROUTER_LABEL_KEY` (default **`cudn.redhat.com/bgp-router`**), `INFRA_EXCLUDE_LABEL_KEY`, `FRR_NAMESPACE`, `FRR_LABEL_KEY`, `FRR_LABEL_VALUE`, `RECONCILE_INTERVAL_SECONDS`, `DEBOUNCE_SECONDS`, `CONTROLLER_NAMESPACE`, `CONTROLLER_DEPLOYMENT_NAME`. After **`canIpForward`** / nested virt, the reconciler sets node annotations **`cudn.redhat.com/gcp-can-ip-forward`** and **`cudn.redhat.com/gcp-nested-virtualization`** (when enabled); **`controller.cleanup`** clears the router label and those annotations.

## Local development

```bash
go test ./...
go build -o bin/manager ./cmd/main.go
```

- **`make run`** / **`make watch`** / **`make cleanup`** — load env from **`cluster_bgp_routing`** via **`terraform output -json`** (**[`scripts/terraform-controller-env-from-json.sh`](../../scripts/terraform-controller-env-from-json.sh)**; needs **`python3`** on **`PATH`**) so an empty state does not capture **`terraform output -raw`** warning text into variables, then `go run ./cmd/main.go` with **`--once`**, default manager, or **`--cleanup`**. **`make cleanup`** skips **`--cleanup`** with a warning when **`CLOUD_ROUTER_NAME`** is empty (stack already torn down or wrong **`TF_DIR`**).
- **`make docker-build`** — `podman build` using the [Dockerfile](Dockerfile) (multi-stage: **UBI 9** + **`yum install go-toolset`** build, **UBI 9 Minimal** runtime with CA certificates).

## In-cluster (OpenShift)

From this directory:

```bash
make deploy-openshift
```

This applies [deploy/](deploy/) via `oc kustomize`, substitutes **`__BGP_CONTROLLER_WIF_AUDIENCE__`** and **`__BGP_CONTROLLER_IMAGE__`** (internal **`ImageStream`** URL), runs **`oc start-build … --from-dir` $PWD** (avoid **`--from-dir=.`** in shell scripts — bash can misparse it as the **`.`** builtin), then **`oc rollout restart`** on the Deployment (same **`ImageStreamTag :latest`** does not change pod spec by itself) and **`oc rollout status`**. The repo root **`make bgp.deploy-controller`** uses [scripts/bgp-deploy-controller-incluster.sh](../../scripts/bgp-deploy-controller-incluster.sh) with **`controller/go/deploy`**; set **`BGP_CONTROLLER_PREBUILT_IMAGE`** to skip **`ImageStream`** / **`BuildConfig`** / **`oc start-build`** (**`make create`** sets it to the published **GHCR** image).

### Workload Identity Federation (ADC in the pod)

The Deployment sets **`GOOGLE_APPLICATION_CREDENTIALS=/var/run/secrets/gcp/credential-config.json`** and mounts:

1. **Secret `bgp-routing-gcp-credentials`** — JSON from **`gcloud iam workload-identity-pools create-cred-config`** ([`scripts/bgp-controller-gcp-credentials.sh`](../../scripts/bgp-controller-gcp-credentials.sh)), with **`credential_source.file`** pointing at the projected token.
2. **Projected service account token** — path **`/var/run/secrets/tokens/gcp-wif/token`**, **`audience`** from Terraform **`wif_kubernetes_token_audience`** (must match the WIF provider’s **`allowedAudiences`**).

On startup the manager logs one line: **`Application Default Credentials`** with **`jsonType`** (**`external_account`** when using WIF), **`credentialSourceFile`**, and whether an impersonation URL is present — **no token or key material**. If GCP returns **403** naming your controller **service account** or required permissions on **`projects/…`**, the call is already authenticated as that SA via WIF; fix **IAM** on the custom role.

## Runtime behavior

- **Logging:** each pass logs **BGP routing reconcile started** / **completed** (trigger node name, router counts, GCP/FRR deltas). Between them, phase lines (selection, **`canIpForward`**, nested virt, NCC, Cloud Router peers, FRR CRs). Set **`DEBUG`** for development-style zap if needed.
- **Leader election** on lease ID `bgp-routing-controller.cudn.redhat.com` in `CONTROLLER_NAMESPACE`.
- **Metrics** on `:8080` (controller-runtime defaults).
- **Probes** on `:8081`: `/healthz` (liveness), `/readyz` (readiness, **Ping** only). Readiness does **not** call GCP so WIF/ADC misconfiguration cannot block OpenShift rollout; reconcile logs surface GCP errors.
- **CLI:** `--once` single reconcile; `--cleanup` full teardown (Deployment, labels, FRR CRs, peers, spokes); default long-running controller.

## RBAC

[deploy/rbac.yaml](deploy/rbac.yaml) includes **`nodes` get/list/watch/patch/update** ( **`update`** is required because label changes use **`client.Update`**) and `deployments` **get/list/delete** for **`--cleanup`**. **Kopf** rules are not used.
