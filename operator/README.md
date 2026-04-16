# BGP Routing Operator

Kubernetes operator for BGP routing on OSD-GCP clusters, built with [Operator SDK](https://sdk.operatorframework.io/).
Replaces the ConfigMap/env-var configuration surface from the legacy controller (archived under [`archive/controller/go/`](../archive/controller/go/README.md)) with two cluster-scoped CRDs under `routing.osd.redhat.com/v1alpha1`.

## CRDs

### BGPRoutingConfig

Cluster-scoped singleton (must be named `cluster`).
Holds all BGP routing configuration in `.spec` and reports aggregated reconciliation state in `.status`.

```yaml
apiVersion: routing.osd.redhat.com/v1alpha1
kind: BGPRoutingConfig
metadata:
  name: cluster
spec:
  gcpProject: my-gcp-project
  cloudRouter:
    name: my-cloud-router
    region: us-east1
  ncc:
    hubName: my-ncc-hub
    spokePrefix: my-spoke
  clusterName: my-osd-cluster
  suspended: false
  frr:
    asn: 65003
  gce:
    enableNestedVirtualization: true
  reconcileIntervalSeconds: 60
  debounceSeconds: 5
```

**Status conditions:** `Ready`, `Degraded`, `Progressing`, `Suspended`.

### BGPRouter

Cluster-scoped, one per elected router node.
Controller-managed via `ownerReferences` pointing to the `BGPRoutingConfig` singleton.
Users should **not** create these manually.

**Status conditions:** `CanIPForwardReady`, `NestedVirtReady`, `NCCSpokeJoined`, `BGPPeersConfigured`, `FRRConfigured`.

## Cleanup

Two independent cleanup triggers:

- **`spec.suspended: true`** — temporarily disables routing, runs cleanup, deletes all `BGPRouter` objects, sets `Suspended` condition.
  Set `spec.suspended: false` to resume with the same configuration.
- **CR deletion** — finalizer `routing.osd.redhat.com/cleanup` runs full teardown (router labels, FRR CRs, BGP peers, NCC spokes) before allowing garbage collection.

## OpenShift reference deploy (`make dev`)

From the repository root (after **`TF_VAR_gcp_project_id`** / **`TF_VAR_cluster_name`** are set):

```bash
make dev
```

This runs **`make bgp.run`** (WIF, cluster, **`configure-routing.sh`**) then **[`scripts/bgp-deploy-operator-incluster.sh`](../scripts/bgp-deploy-operator-incluster.sh)**:

1. Applies **`controller_gcp_iam/`** and the WIF credential **Secret**.
2. Applies CRDs from **`config/crd/bases/`**.
3. Applies **`deploy/rbac.yaml`** (ServiceAccount **`bgp-routing-operator`**, ClusterRole, ClusterRoleBinding).
4. Creates or updates **`BGPRoutingConfig`** `cluster` from **`cluster_bgp_routing`** Terraform outputs.
5. **`oc start-build`** from this directory (ImageStream **`bgp-routing-operator:latest`**) and rollouts **`deployment/bgp-routing-operator`**.

Optional prebuilt image (skip BuildConfig binary build):

```bash
make bgp.run
make bgp.deploy-operator BGP_OPERATOR_PREBUILT_IMAGE=ghcr.io/your-org/osd-gcp-cudn-routing/bgp-routing-operator:latest
make post-operator-deploy-msg
```

## Development

```bash
# Build
make build

# Run tests
make test

# Generate deepcopy and manifests
make generate manifests

# Build container image
make docker-build IMG=ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-routing-operator:dev

# Deploy to cluster (with kustomize)
make deploy IMG=ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-routing-operator:dev
```

From the repo root:

```bash
make operator.build
make operator.test
make operator.generate
make operator.manifests
make operator.docker-build
```

## Migration from legacy controller

If you previously ran the archived `controller/go/`, follow these steps:

1. Deploy CRDs: `kubectl apply -f config/crd/bases/`
2. Create a `BGPRoutingConfig` CR with values from the existing ConfigMap.
3. Deploy the operator (swap the controller Deployment for the operator Deployment).
4. Verify `BGPRouter` objects are created and conditions are `True`.
5. Remove the old controller Deployment, ConfigMap, and RBAC.
6. (Optional) Strip stale `cudn.redhat.com/*` labels and annotations from nodes.

The operator uses `routing.osd.redhat.com` for all labels and annotations.
Clusters previously running the legacy controller will have `cudn.redhat.com/*` metadata on nodes.
A migration script to strip stale metadata is planned for a future phase.

## Labels and annotations

| Purpose | Old (legacy controller) | New (operator) |
|---------|----------------------|----------------|
| Router node label | `cudn.redhat.com/bgp-router` | `routing.osd.redhat.com/bgp-router` |
| FRR CR label key | `cudn.redhat.com/bgp-stack` | `routing.osd.redhat.com/bgp-stack` |
| canIpForward annotation | `cudn.redhat.com/gcp-can-ip-forward` | `routing.osd.redhat.com/gcp-can-ip-forward` |
| Nested virt annotation | `cudn.redhat.com/gcp-nested-virtualization` | `routing.osd.redhat.com/gcp-nested-virtualization` |
| Leader election ID | `bgp-routing-controller.cudn.redhat.com` | `bgp-routing-operator.routing.osd.redhat.com` |
