# TODO: Fix BGP Blocking Node Drain During Cluster Upgrades

## Problem

When OpenShift replaces a worker node (upgrade, scale, repair), the Machine API tries to
delete the underlying GCE instance. GCP rejects this with:

```
googleapi: Error 400: Invalid resource usage: 'Resource cannot be deleted because there
is a BGP peer configured with a router bgp151-cudn-cr.'
```

### Root Cause

The Cloud Router BGP peer references each worker GCE instance via `RouterApplianceInstance`.
GCP enforces that an instance **cannot be deleted** while such a peer exists.

The operator removes peers _eventually_ — after the Kubernetes Node disappears from
`DiscoverCandidates` — but the Machine API deletes the GCE instance **before** the Node
is removed. There is no ordering guarantee:

```
Machine DeletionTimestamp set
  → Machine controller drains node
  → Machine controller calls GCP deleteInstance()  ← FAILS: BGP peer still exists
  → Machine controller retries in a loop
  → Node is never cleaned up
```

### Why a Node Finalizer Won't Work

The Node `DeletionTimestamp` is set **after** a successful GCE instance deletion. Since
the GCE deletion is the step that fails, the node finalizer never fires. The hook point
is too late.

---

## Solution: OpenShift Machine `preTerminate` Lifecycle Hook

OpenShift Machine API v1beta1 supports `spec.lifecycleHooks.preTerminate`. When any hook
is present, the Machine controller **blocks** before calling the cloud provider delete
API. This provides a hard ordering guarantee.

The operator becomes the hook owner:

```
Machine DeletionTimestamp set
  → Machine controller sees our preTerminate hook → sets PreTerminateHookSucceeded=False, STOPS
  → Operator watch fires, detects DeletionTimestamp + hook on this Machine
  → Operator removes BGP peers for that instance from the Cloud Router
  → Operator removes the lifecycle hook from the Machine
  → Machine controller resumes → calls GCP deleteInstance() → SUCCEEDS
  → Machine controller deletes the Node
  → Operator reconciles, node gone from candidates, stable state
```

---

## Implementation Tasks

### Task 1 — Add `MachineNamespace` to `BGPRoutingConfig` spec

**Files:**
- `operator/api/v1alpha1/bgproutingconfig_types.go`
- `operator/internal/controller/bgproutingconfig_controller.go` (wire into `ReconcilerConfig`)
- `operator/internal/reconciler/config.go` (add field to `ReconcilerConfig`)
- `operator/config/crd/bases/routing.osd.redhat.com_bgproutingconfigs.yaml` (regenerate or hand-edit)

**What to do:**

Add an optional `machineNamespace` field to `BGPRoutingConfig.spec` with default
`openshift-machine-api`. This avoids hardcoding the Machine namespace.

```go
// In BGPRoutingConfigSpec:
// +kubebuilder:default="openshift-machine-api"
MachineNamespace string `json:"machineNamespace,omitempty"`
```

Add `MachineNamespace string` to `ReconcilerConfig` and wire it from the spec in the
controller's config-building function.

---

### Task 2 — Create `operator/internal/reconciler/machines.go`

Use the **unstructured client** (same pattern as `frr.go`) — no `github.com/openshift/api`
dependency needed.

**Constants:**

```go
const (
    MachineGroup            = "machine.openshift.io"
    MachineVersion          = "v1beta1"
    MachineKind             = "Machine"
    MachineResource         = "machines"
    BGPLifecycleHookName    = "routing.osd.redhat.com/bgp-cleanup"
    BGPLifecycleHookOwner   = "BGPRoutingConfig"
)
```

**Internal type:**

```go
type terminatingMachine struct {
    Name      string // Machine object name
    Namespace string
    SelfLink  string // GCE instance selfLink (from providerID)
}
```

**`FindTerminatingMachines(ctx, client, cfg, routerSelfLinks map[string]struct{}) ([]terminatingMachine, error)`**

1. List all Machines in `cfg.MachineNamespace` using the unstructured client.
2. If the `machine.openshift.io` API group is not registered (non-OCP cluster), detect
   the 404/discovery error and return `nil, nil` (no-op).
3. Parse each Machine's `spec.providerID` using the same regex already in `nodes.go`
   to extract the GCE instance name and build a selfLink.
4. For each Machine whose selfLink is in `routerSelfLinks`:
   - If `metadata.deletionTimestamp` is set AND our hook is present in
     `spec.lifecycleHooks.preTerminate` → append to the returned terminating list.
   - If `metadata.deletionTimestamp` is **not** set AND our hook is **absent** →
     add the hook via a patch (idempotent).
5. For Machines whose selfLink is **not** in `routerSelfLinks` but our hook is present
   → remove the hook (cleanup for nodes no longer in the BGP set).

Hook add/remove helpers (unexported):

```go
func addLifecycleHook(ctx context.Context, c client.Client, m *unstructured.Unstructured) error
func removeLifecycleHook(ctx context.Context, c client.Client, m *unstructured.Unstructured) error
```

Both patch `spec.lifecycleHooks.preTerminate` — add/remove the entry with
`name: routing.osd.redhat.com/bgp-cleanup` and `owner: BGPRoutingConfig`.

**`ReleaseMachines(ctx, client, machines []terminatingMachine) error`**

Iterates the terminating list and removes our lifecycle hook from each Machine.
Called **after** `ReconcilePeers` succeeds (so the BGP peer is gone before unblocking).

---

### Task 3 — Update `operator/internal/reconciler/reconciler.go`

Insert two new steps in `Reconcile`, wrapping the existing `ReconcilePeers` call:

```go
// --- BEFORE GetRouterTopology / ReconcilePeers ---

// Step A: Find terminating machines and add hooks to active BGP router machines.
routerSelfLinks := selfLinkSet(routerNodes)   // build map[selfLink]struct{}
terminating, err := FindTerminatingMachines(ctx, r.Client, r.Cfg, routerSelfLinks)
if err != nil {
    return res, fmt.Errorf("machine lifecycle hooks: %w", err)
}

// Step B: Exclude terminating instances from the peer reconciliation so their
//         peers are removed from the Cloud Router.
filteredNodes := excludeTerminating(routerNodes, terminating)

// --- EXISTING topology + ReconcilePeers (use filteredNodes) ---
topology, err := r.Compute.GetRouterTopology(ctx, r.Cfg.CloudRouterName)
...
peerChanged, err := r.Compute.ReconcilePeers(
    ctx, r.Cfg.CloudRouterName, r.Cfg.ClusterName,
    filteredNodes,   // ← was routerNodes
    topology, r.Cfg.FRRASN,
)
...

// Step C: After peers are removed, release hooks to unblock Machine deletion.
if err := ReleaseMachines(ctx, r.Client, terminating); err != nil {
    return res, fmt.Errorf("release machine hooks: %w", err)
}
```

Add two small helpers in this file or `nodes.go`:

```go
func selfLinkSet(nodes []gcp.RouterNode) map[string]struct{}
func excludeTerminating(nodes []gcp.RouterNode, terminating []terminatingMachine) []gcp.RouterNode
```

Note: `filteredNodes` is also passed to `ReconcileFRRConfigurations` and
`ReconcileNCCSpokes` — use it there too so those resources are cleaned up consistently
for terminating nodes.

---

### Task 4 — Add Machine watch to `operator/internal/controller/bgproutingconfig_controller.go`

**Refactor the existing node event filter:**

`WithEventFilter` on the controller builder applies to **all** watched types. Move the
node-specific predicate from `WithEventFilter` to the `Watches` call:

```go
// Before:
Watches(&corev1.Node{}, nodeHandler).
WithEventFilter(nodeEventFilter{})

// After:
Watches(&corev1.Node{}, nodeHandler, builder.WithPredicates(nodeEventFilter{}))
```

**Add a Machine watch:**

```go
machineObj := &unstructured.Unstructured{}
machineObj.SetGroupVersionKind(schema.GroupVersionKind{
    Group:   "machine.openshift.io",
    Version: "v1beta1",
    Kind:    "Machine",
})

Watches(machineObj,
    handler.EnqueueRequestsFromMapFunc(func(_ context.Context, _ client.Object) []reconcile.Request {
        return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: singletonName}}}
    }),
    builder.WithPredicates(machineEventFilter{}),
)
```

**`machineEventFilter`** (new type, same file):

```go
type machineEventFilter struct{}

func (machineEventFilter) Create(e event.CreateEvent) bool  { return true }
func (machineEventFilter) Delete(e event.DeleteEvent) bool  { return true }
func (machineEventFilter) Generic(e event.GenericEvent) bool { return false }

func (machineEventFilter) Update(e event.UpdateEvent) bool {
    // Enqueue when deletionTimestamp transitions nil → non-nil,
    // or when spec.lifecycleHooks.preTerminate changes.
    oldU, ok1 := e.ObjectOld.(*unstructured.Unstructured)
    newU, ok2 := e.ObjectNew.(*unstructured.Unstructured)
    if !ok1 || !ok2 {
        return true
    }
    oldDeleting := oldU.GetDeletionTimestamp() != nil
    newDeleting := newU.GetDeletionTimestamp() != nil
    if !oldDeleting && newDeleting {
        return true
    }
    // detect hook list change (simplified: compare as JSON or nested field)
    return !reflect.DeepEqual(
        oldU.Object["spec"].(map[string]interface{})["lifecycleHooks"],
        newU.Object["spec"].(map[string]interface{})["lifecycleHooks"],
    )
}
```

---

### Task 5 — Update RBAC

**File:** `operator/config/rbac/role.yaml`

Add:

```yaml
- apiGroups:
  - machine.openshift.io
  resources:
  - machines
  verbs:
  - get
  - list
  - patch
  - update
  - watch
```

---

### Task 6 — Documentation and Changelog

**`CHANGELOG.md`** — add under `## [Unreleased]` → `Fixed`:

```
- Fixed: BGP peer blocking GCE instance deletion during node replacement/upgrade.
  The operator now registers a `preTerminate` lifecycle hook on each BGP router
  Machine and removes the Cloud Router peer before unblocking instance termination.
```

**`operator/README.md`** — add a section explaining:
- The operator adds a `preTerminate` lifecycle hook (`routing.osd.redhat.com/bgp-cleanup`)
  to every Machine that is a BGP router appliance.
- This ensures BGP peers are cleanly removed before instance deletion, preventing the
  GCP 400 error during cluster upgrades.
- The `spec.machineNamespace` field (default: `openshift-machine-api`) controls where
  the operator looks for Machine objects.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| `preTerminate` hook instead of node finalizer | Node DeletionTimestamp is set after GCE deletion — too late. The hook blocks before the cloud call. |
| Unstructured client for Machines | Avoids adding `github.com/openshift/api` as a heavy dependency, consistent with how `FRRConfiguration` is handled. |
| Filter terminating nodes from `ReconcilePeers` | The existing full-set-patch approach in `ReconcilePeers` naturally removes the peer when the node is excluded — no new GCP API needed. |
| No-op on missing `machine.openshift.io` API | Keeps the operator functional on non-OCP clusters (e.g., local dev, kind). |
| Release hooks only after `ReconcilePeers` succeeds | Guarantees the BGP peer is gone before unblocking the Machine controller. If `ReconcilePeers` fails, the hook stays and the controller retries on next reconcile. |
