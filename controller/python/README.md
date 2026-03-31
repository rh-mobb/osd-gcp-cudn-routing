# BGP Routing Controller (Python / kopf)

Watches Kubernetes **Node** objects and automatically reconciles the GCP and OpenShift resources that make BGP-based CUDN routing work. When a worker (or router-pool) node is **added, replaced, or removed**, the controller:

1. Enables **`canIpForward`** on the backing GCE instance
2. Creates or updates the **NCC Router Appliance spoke** to list exactly the current set of router nodes
3. Updates **Cloud Router BGP peers** (2 per node — one per interface)
4. Creates / updates / deletes **`FRRConfiguration`** CRs so each router node peers with both Cloud Router interface IPs

Terraform manages only the **static** infrastructure (NCC hub, Cloud Router, interfaces, firewalls). The controller owns all **dynamic** resources that change with node lifecycle.

This is the **quick-win** implementation described in [PRODUCTION-ROADMAP.md § 4F](../../cluster_bgp_routing/PRODUCTION-ROADMAP.md). A Go / controller-runtime version can follow in `controller/go/` using the same reconciliation design.

## Prerequisites

- Terraform BGP stack deployed (`cluster_bgp_routing` with `enable_bgp_routing=true`)
- `configure-routing.sh` has been run at least once (FRR enabled, CUDN created, RouteAdvertisements in place)
- **GCP IAM + in-cluster credentials** — from the repo root, **`make bgp.deploy-controller`** after **`make bgp.run`** (or follow [`controller_gcp_iam/README.md`](../../controller_gcp_iam/README.md) and **`make controller.gcp-credentials`** manually)

### GCP IAM (custom role — least privilege)

[`modules/osd-bgp-controller-iam/`](../../modules/osd-bgp-controller-iam/README.md) creates a dedicated GCP service account and custom role with exactly these permissions:

```yaml
title: BGP Routing Controller
permissions:
  - compute.instances.get
  - compute.instances.list
  - compute.instances.update
  - compute.zones.list
  - networkconnectivity.operations.get
  - networkconnectivity.spokes.create
  - networkconnectivity.spokes.delete
  - networkconnectivity.spokes.get
  - networkconnectivity.spokes.list
  - networkconnectivity.spokes.update
  - compute.routers.get
  - compute.routers.update
```

### WIF credentials (automated)

**Recommended (in-cluster operator, no hand-edited ConfigMap):** from the repo root, after **`make bgp.run`**:

```bash
make bgp.deploy-controller
```

That applies [**`controller_gcp_iam/`**](../../controller_gcp_iam/README.md), creates the WIF credential **Secret**, renders the **ConfigMap** from **`cluster_bgp_routing` `terraform output`**, and runs the OpenShift build + rollout ([`scripts/bgp-deploy-controller-incluster.sh`](../../scripts/bgp-deploy-controller-incluster.sh)).

**Piecemeal (experts):** same **`TF_VAR_*`** as the cluster — **`make controller.gcp-iam.apply`**, then **`CONTROLLER_GCP_CRED_APPLY_SECRET=1 make controller.gcp-credentials`**, then edit **`deploy/configmap.yaml`** or use **`make deploy-openshift`** (from **`controller/python/`**; substitutes WIF **`audience`** from **`controller_gcp_iam`** Terraform output). Requires **`gcloud auth application-default login`** and **`oc`** logged in.

**If logs show `invalid_grant` / audience mismatch:** the projected token’s **`audience`** must be **one of** the OIDC provider’s **`allowedAudiences`** (run **`gcloud iam workload-identity-pools providers describe`**). OSD/OCM WIF usually lists **`openshift`**, not **`https://openshift.com`** or **`//iam.googleapis.com/...`** — set Terraform **`wif_kubernetes_token_audience`** (default **`openshift`**) and **`make bgp.deploy-controller`**. The credential JSON still uses **`//iam.googleapis.com/...`** from **`create-cred-config`** ([AIP-4117](https://google.aip.dev/auth/4117)); that is separate from the Kubernetes JWT **`aud`**.

Details and destroy order: [`controller_gcp_iam/README.md`](../../controller_gcp_iam/README.md).

## Configuration

All configuration is via environment variables (see `deploy/configmap.yaml`):

**Router node selection:** The controller lists **worker candidates** with `NODE_LABEL_KEY` / `NODE_LABEL_VALUE`, **excludes** any node that has `INFRA_EXCLUDE_LABEL_KEY` (default **`node-role.kubernetes.io/infra`**), then picks **up to** `ROUTER_NODE_COUNT` nodes (**`0`** = auto: **2** if all candidates share one `topology.kubernetes.io/zone`, **3** if two or more zones). Selection **round-robins across zones**; within each zone, nodes already labeled with `ROUTER_LABEL_KEY` are preferred. Chosen nodes get **`ROUTER_LABEL_KEY`** (default **`node-role.kubernetes.io/bgp-router`**) so you can see which instances peer with the Cloud Router; the label is removed when a node drops out of the selected set. **`make controller.cleanup`** / **`--cleanup`** deletes the **`Deployment`** in **`CONTROLLER_NAMESPACE`** (default **`bgp-routing-system`**) named **`CONTROLLER_DEPLOYMENT_NAME`** (default **`bgp-routing-controller`**) if it exists, then strips **`ROUTER_LABEL_KEY`** from every node, then removes FRR CRs and GCP resources.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GCP_PROJECT` | yes | | GCP project ID |
| `CLUSTER_NAME` | yes | | OSD cluster name (Terraform `cluster_name`) |
| `CLOUD_ROUTER_NAME` | yes | | Cloud Router name (Terraform output `cloud_router_name`) |
| `CLOUD_ROUTER_REGION` | yes | | GCP region |
| `NCC_HUB_NAME` | yes | | NCC hub name (Terraform output `ncc_hub_name`) |
| `NCC_SPOKE_NAME` | yes | | NCC spoke name (Terraform output `ncc_spoke_name`) |
| `FRR_ASN` | | `65003` | FRR ASN (must match Terraform `frr_asn`) |
| `NCC_SPOKE_SITE_TO_SITE` | | `false` | site_to_site_data_transfer on the NCC spoke |
| `NODE_LABEL_KEY` | | `node-role.kubernetes.io/worker` | Label selector for **candidate** workers (not infra) |
| `NODE_LABEL_VALUE` | | _(empty = key-exists)_ | Candidate label value (empty matches any value) |
| `ROUTER_NODE_COUNT` | | `0` | Max BGP router nodes (`0` = auto: 2 single-AZ, 3 multi-AZ) |
| `ROUTER_LABEL_KEY` | | `node-role.kubernetes.io/bgp-router` | Label applied to **selected** router nodes |
| `INFRA_EXCLUDE_LABEL_KEY` | | `node-role.kubernetes.io/infra` | Candidates with this label key are skipped |
| `RECONCILE_INTERVAL_SECONDS` | | `60` | Periodic drift reconciliation interval |
| `DEBOUNCE_SECONDS` | | `5` | Minimum time between event-driven reconciliations |
| `CONTROLLER_NAMESPACE` | | `bgp-routing-system` | Namespace of the controller **Deployment** (for **`--cleanup`**) |
| `CONTROLLER_DEPLOYMENT_NAME` | | `bgp-routing-controller` | **Deployment** name to delete on **`--cleanup`** |

Most required values come directly from `terraform output`:

```bash
terraform output -raw cloud_router_name    # → CLOUD_ROUTER_NAME
terraform output -raw gcp_project_id       # → GCP_PROJECT
terraform output -raw cluster_name         # → CLUSTER_NAME
terraform output -raw gcp_region           # → CLOUD_ROUTER_REGION
terraform output -raw ncc_hub_name         # → NCC_HUB_NAME
terraform output -raw ncc_spoke_name       # → NCC_SPOKE_NAME
```

## Local development

**Recommended (from `controller/python/`):**

```bash
cd controller/python

# Create venv and install dependencies
make venv

# One-shot: reconcile once and exit (initial setup, CI, make bgp.run)
make run

# Long-lived operator: watch for node changes and reconcile continuously
make watch

# Teardown: delete in-cluster Deployment (if any), peers, spoke, FRR CRs, router labels
make cleanup
```

Both targets read all required env vars from `terraform output` in `../../cluster_bgp_routing/` (override with `TF_DIR=path/to/cluster_bgp_routing`). They use `~/.config/gcloud/application_default_credentials.json` for GCP auth — run `gcloud auth application-default login` first.

**Manual setup (without Make):**

```bash
cd controller/python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

export KUBECONFIG=~/.kube/config
export GCP_PROJECT=my-project
export CLUSTER_NAME=my-cluster
export CLOUD_ROUTER_NAME=my-cluster-cudn-cr
export CLOUD_ROUTER_REGION=us-central1
export NCC_HUB_NAME=my-cluster-ncc-hub
export NCC_SPOKE_NAME=my-cluster-ra-spoke
export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json

# One-shot
python -m bgp_routing_controller --once

# Long-lived operator
python -m bgp_routing_controller

# Cleanup (Deployment if present, labels, FRR, GCP peers/spoke)
python -m bgp_routing_controller --cleanup
```

### Makefile targets

| Target | Description |
|--------|-------------|
| `make venv` | Create virtualenv and install `requirements.txt` |
| `make run` | One-shot reconciliation and exit |
| `make watch` | Long-lived operator (kopf event loop) |
| `make cleanup` | Delete controller Deployment (if any), then all other managed resources |
| `make build` | Build container image with podman (local tag only) |
| `make deploy-openshift` | `oc apply -k deploy/` + binary `BuildConfig` + wait for rollout (OpenShift) |
| `make lint` | Compile-check all Python modules |
| `make clean` | Remove virtualenv and `__pycache__` |

## Build and deploy

Manifests live under `deploy/` (kustomize). They target **OpenShift** (`ImageStream`, `BuildConfig`, `Deployment` pulling the cluster internal registry).

1. **Config and credentials**
   - **Automated:** from the repo root, **`make bgp.deploy-controller`** after **`make bgp.run`** ([§ WIF credentials (automated)](#wif-credentials-automated)).
   - **Manual:** edit **`deploy/configmap.yaml`**, apply **`controller_gcp_iam/`**, and **`make controller.gcp-credentials`** (with **`CONTROLLER_GCP_CRED_APPLY_SECRET=1`** for the Secret).

2. **Build in-cluster and run from the internal registry (recommended on OpenShift)**

From `controller/python/` (so the Docker build context includes the `Dockerfile` and source):

```bash
make deploy-openshift
# Same as:
#   oc apply -k deploy/
#   oc start-build bgp-routing-controller -n bgp-routing-system --from-dir=. --follow
#   oc rollout status deployment/bgp-routing-controller -n bgp-routing-system --timeout=180s
```

Override namespace with `NS=my-namespace make deploy-openshift`.

The `BuildConfig` uses **Binary** source and **`triggers: []`**, so nothing uploads until you run `oc start-build … --from-dir=.`. The `Deployment` image is `image-registry.openshift-image-registry.svc:5000/bgp-routing-system/bgp-routing-controller:latest` — expect **`ImagePullBackOff` until the first build finishes**.

3. **Local image only (podman / external registry)**

```bash
make build
# Push to your registry and change the Deployment image, or use ImageStream import — then:
kubectl apply -k deploy/
```

## How it works

### Triggers

- **Event-driven:** watches all Node events via `kopf.on.event`; filters to nodes with the configured label selector; debounces rapid events
- **Periodic:** background thread reconciles every `RECONCILE_INTERVAL_SECONDS` for drift detection

### Reconciliation sequence

```
Node event (or timer)
  │
  ├─ 1. List K8s Nodes matching label selector
  │     Extract GCE instance info from Node.spec.providerID + status.addresses
  │
  ├─ 2. canIpForward — GET each instance, PATCH if false
  │
  ├─ 3. NCC spoke — GET spoke (create if missing), compare linked instances, PATCH if drift
  │     (must complete before peers can work)
  │
  ├─ 4. Cloud Router peers — GET router, compute desired peer list, PATCH if drift
  │     (2 peers per node: one per Cloud Router interface)
  │
  └─ 5. FRRConfiguration CRs — create missing, delete stale
        (each CR: nodeSelector → hostname, 2 neighbors → Cloud Router IPs,
         raw config → disable-connected-check)
```

### Ownership split

| Resource | Owner | Notes |
|----------|-------|-------|
| NCC hub | Terraform | Static — one per cluster |
| Cloud Router + interfaces | Terraform | Static — HA pair |
| Firewall rules | Terraform | Static — subnet/CUDN/BGP rules |
| NCC spoke | **Controller** | Created on first reconciliation |
| Cloud Router BGP peers | **Controller** | 2 per router node |
| `canIpForward` | **Controller** | Enabled per GCE instance |
| `FRRConfiguration` CRs | **Controller** | 1 per router node |
| FRR enable / CUDN / RouteAdvertisements | `configure-routing.sh` | One-time setup |
