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
- GCP service account with the custom role below, bound to WIF

### GCP IAM (custom role — least privilege)

```yaml
title: BGP Routing Controller
permissions:
  - compute.instances.get
  - compute.instances.list
  - compute.instances.update
  - compute.zones.list
  - networkconnectivity.spokes.create
  - networkconnectivity.spokes.delete
  - networkconnectivity.spokes.get
  - networkconnectivity.spokes.list
  - networkconnectivity.spokes.update
  - compute.routers.get
  - compute.routers.update
```

### WIF credential setup

1. Create the GCP SA and grant the custom role:

```bash
gcloud iam service-accounts create bgp-routing-controller \
  --project=PROJECT_ID \
  --display-name="BGP Routing Controller"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:bgp-routing-controller@PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/PROJECT_ID/roles/BgpRoutingController"
```

2. Bind to the WIF pool so the K8s ServiceAccount can authenticate:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  bgp-routing-controller@PROJECT_ID.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUM/locations/global/workloadIdentityPools/POOL_ID/attribute.sub/system:serviceaccount:bgp-routing-system:bgp-routing-controller"
```

3. Create the credential configuration file and store it as a K8s Secret:

```bash
gcloud iam workload-identity-pools create-cred-config \
  projects/PROJECT_NUM/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID \
  --service-account=bgp-routing-controller@PROJECT_ID.iam.gserviceaccount.com \
  --credential-source-file=/var/run/secrets/kubernetes.io/serviceaccount/token \
  --credential-source-type=text \
  --output-file=credential-config.json

kubectl create secret generic bgp-routing-gcp-credentials \
  -n bgp-routing-system \
  --from-file=credential-config.json=credential-config.json
```

## Configuration

All configuration is via environment variables (see `deploy/configmap.yaml`):

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
| `NODE_LABEL_KEY` | | `node-role.kubernetes.io/worker` | Label key to select router nodes (must match nodes where OVN-K injects CUDN routes) |
| `NODE_LABEL_VALUE` | | _(empty = key-exists)_ | Label value (empty matches any value) |
| `RECONCILE_INTERVAL_SECONDS` | | `60` | Periodic drift reconciliation interval |
| `DEBOUNCE_SECONDS` | | `5` | Minimum time between event-driven reconciliations |

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

# One-shot: reconcile once and exit (initial setup, CI, make bgp-apply)
make run

# Long-lived operator: watch for node changes and reconcile continuously
make watch

# Teardown: delete all controller-managed resources (peers, spoke, FRR CRs)
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

# Cleanup (delete all controller-managed resources)
python -m bgp_routing_controller --cleanup
```

### Makefile targets

| Target | Description |
|--------|-------------|
| `make venv` | Create virtualenv and install `requirements.txt` |
| `make run` | One-shot reconciliation and exit |
| `make watch` | Long-lived operator (kopf event loop) |
| `make cleanup` | Delete all controller-managed resources |
| `make build` | Build container image with podman (local tag only) |
| `make deploy-openshift` | `oc apply -k deploy/` + binary `BuildConfig` + wait for rollout (OpenShift) |
| `make lint` | Compile-check all Python modules |
| `make clean` | Remove virtualenv and `__pycache__` |

## Build and deploy

Manifests live under `deploy/` (kustomize). They target **OpenShift** (`ImageStream`, `BuildConfig`, `Deployment` pulling the cluster internal registry).

1. **Config and credentials**
   - Edit `deploy/configmap.yaml` with Terraform outputs (`GCP_PROJECT`, `CLOUD_ROUTER_NAME`, …).
   - Ensure namespace `bgp-routing-system` exists and the WIF GCP credential secret exists (see [§ WIF credential setup](#wif-credential-setup)).

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
