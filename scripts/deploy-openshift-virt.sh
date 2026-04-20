#!/usr/bin/env bash
# Deploy OpenShift Virtualization (CNV) and configure RWX storage for GCP.
#
# Creates the Hyperdisk storage pool (if needed), default Hyperdisk StorageClass,
# VolumeSnapshotClass for image snapshots, then installs the kubevirt-hyperconverged
# operator via OLM and creates a HyperConverged CR.
#
# Reads GCP project / region / zone from cluster_bgp_routing terraform outputs.
# Zone: virt_storage_zone (bare metal pool AZ when create_baremetal_worker_pool is true), else first availability_zones entry.
#
# Environment variables:
#   STORAGE_POOL_NAME         Name of the Hyperdisk storage pool (default: ocp-virt-pool)
#   STORAGE_POOL_PROVISIONED_CAPACITY  gcloud --provisioned-capacity (default: 10240GiB = 10 TiB, GCP min)
#   STORAGE_POOL_CAPACITY_GB  Deprecated: if set and CAPACITY unset, expands to "${VALUE}GiB" (10240 = 10 TiB)
#   STORAGE_POOL_PROVISIONED_IOPS      Pool IOPS (default: 10000; must be a multiple of 10000 per GCP)
#   STORAGE_POOL_PROVISIONED_THROUGHPUT  MiB/s (default: 1024 = 1 GiB/s; min 1024; multiples of 1024 per GCP)
#   CNV_CHANNEL               OLM channel (default: stable — matches OperatorHub / OCP doc)
#   CNV_SUBSCRIPTION_NAME     Subscription object name (default: hco-operatorhub)
#   CNV_PACKAGE_NAME          Catalog package (default: kubevirt-hyperconverged)
#   CNV_STARTING_CSV          Optional InstallPlan pin (e.g. kubevirt-hyperconverged-operator.v4.21.3)
#   SKIP_STORAGE              Set to 1 to skip Hyperdisk StorageClass + VolumeSnapshotClass
#   CNV_WAIT_TIMEOUT          Timeout for operator/HyperConverged readiness (default: 600s)
#   CNV_WAIT_DIAG_INTERVAL_SEC  While resolving CSV name, print OLM diagnostics every N seconds (default: 30)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"

STORAGE_POOL_NAME="${STORAGE_POOL_NAME:-ocp-virt-pool}"
STORAGE_POOL_CAPACITY_GB="${STORAGE_POOL_CAPACITY_GB:-}"
STORAGE_POOL_PROVISIONED_CAPACITY="${STORAGE_POOL_PROVISIONED_CAPACITY:-}"
STORAGE_POOL_PROVISIONED_IOPS="${STORAGE_POOL_PROVISIONED_IOPS:-10000}"
STORAGE_POOL_PROVISIONED_THROUGHPUT="${STORAGE_POOL_PROVISIONED_THROUGHPUT:-1024}"
CNV_CHANNEL="${CNV_CHANNEL:-}"
SKIP_STORAGE="${SKIP_STORAGE:-}"
CNV_WAIT_TIMEOUT="${CNV_WAIT_TIMEOUT:-600s}"

CNV_NAMESPACE="openshift-cnv"
# OCP 4.x OperatorHub + CLI install use this Subscription name (not "kubevirt-hyperconverged").
# See: https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/installing
CNV_SUBSCRIPTION_NAME="${CNV_SUBSCRIPTION_NAME:-hco-operatorhub}"
CNV_PACKAGE_NAME="${CNV_PACKAGE_NAME:-kubevirt-hyperconverged}"
CNV_STARTING_CSV="${CNV_STARTING_CSV:-}"
VSC_IMAGES_URL="https://raw.githubusercontent.com/openshift/gcp-pd-csi-driver-operator/main/assets/volumesnapshotclass_images.yaml"

# OLM sets status.currentCSV as soon as a CSV exists; installedCSV often appears only after Succeeded.
# Waiting only on installedCSV can look "stuck" for the full timeout with no progress output.
CNV_WAIT_DIAG_INTERVAL_SEC="${CNV_WAIT_DIAG_INTERVAL_SEC:-30}"

# --- prerequisites -------------------------------------------------------

for cmd in oc terraform gcloud jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: required command '$cmd' not found on PATH." >&2
    exit 1
  }
done

oc whoami >/dev/null 2>&1 || {
  echo "Error: not logged in — run 'make bgp.run' first (or oc login)." >&2
  exit 1
}

# --- terraform outputs ---------------------------------------------------

echo "=== Reading cluster_bgp_routing terraform outputs ==="
cd "$CLUSTER_DIR"
GCP_PROJECT=$(terraform output -raw gcp_project_id)
GCP_REGION=$(terraform output -raw gcp_region)

GCP_ZONE=$(terraform output -raw virt_storage_zone 2>/dev/null || true)
if [[ -z "$GCP_ZONE" ]]; then
  ZONE_JSON=$(terraform output -json availability_zones 2>/dev/null || echo '[]')
  GCP_ZONE=$(echo "$ZONE_JSON" | jq -r '.[0] // empty')
fi
if [[ -z "$GCP_ZONE" ]]; then
  GCP_ZONE="${GCP_REGION}-a"
  echo "  No virt_storage_zone / availability_zones; defaulting to ${GCP_ZONE}"
fi

echo "  project=${GCP_PROJECT}  region=${GCP_REGION}  zone=${GCP_ZONE}"

# --- OLM channel (match OperatorHub / OCP virtualization install doc) ---

if [[ -z "$CNV_CHANNEL" ]]; then
  # Product doc and OperatorHub use channel "stable" for kubevirt-hyperconverged on redhat-operators.
  CNV_CHANNEL="stable"
  echo "  Using OLM channel: ${CNV_CHANNEL} (override with CNV_CHANNEL=...)"
fi

# Optional CNV_STARTING_CSV (e.g. kubevirt-hyperconverged-operator.v4.21.3) — doc includes this;
# omit by default so OLM picks the latest CSV in channel "stable".

wait_timeout_seconds() {
  # Strip trailing "s" from values like "600s" for arithmetic.
  local t="${CNV_WAIT_TIMEOUT%s}"
  [[ "$t" =~ ^[0-9]+$ ]] || t=600
  printf '%s' "$t"
}

# Resolve the ClusterServiceVersion name for kubevirt-hyperconverged (OLM).
# Prefer currentCSV / installedCSV from Subscription; fall back to listing CSVs in the namespace.
resolve_cnv_csv_name() {
  local cur inst list
  cur=$(oc get subscription "$CNV_SUBSCRIPTION_NAME" -n "$CNV_NAMESPACE" \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  [[ -n "$cur" ]] && { printf '%s' "$cur"; return 0; }
  inst=$(oc get subscription "$CNV_SUBSCRIPTION_NAME" -n "$CNV_NAMESPACE" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  [[ -n "$inst" ]] && { printf '%s' "$inst"; return 0; }
  list=$(oc get csv -n "$CNV_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  printf '%s' "$(printf '%s\n' "$list" | grep -E '^kubevirt-hyperconverged' | head -n1)"
}

print_subscription_diag() {
  echo "  --- OLM snapshot (${CNV_NAMESPACE}/subscription/${CNV_SUBSCRIPTION_NAME}) ---"
  oc get subscription "$CNV_SUBSCRIPTION_NAME" -n "$CNV_NAMESPACE" -o wide 2>/dev/null || true
  echo "  conditions (if any):"
  oc get subscription "$CNV_SUBSCRIPTION_NAME" -n "$CNV_NAMESPACE" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null || echo "    (none)"
  echo "  installplans:"
  oc get installplan -n "$CNV_NAMESPACE" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,APPROVAL:.spec.approved 2>/dev/null || true
  echo "  csv (kubevirt):"
  if ! oc get csv -n "$CNV_NAMESPACE" -o wide 2>/dev/null | grep -E 'kubevirt-hyperconverged|^NAME'; then
    oc get csv -n "$CNV_NAMESPACE" --no-headers 2>/dev/null | head -5 || true
  fi
}

# Fail fast before gcloud/oc storage mutations. See:
# https://cloud.google.com/compute/docs/disks/create-storage-pools
# https://cloud.google.com/compute/docs/disks/storage-pools#pool-limits
validate_storage_inputs() {
  local cap="$STORAGE_POOL_PROVISIONED_CAPACITY"
  local iops="$STORAGE_POOL_PROVISIONED_IOPS"
  local tp="$STORAGE_POOL_PROVISIONED_THROUGHPUT"
  local gib tib

  command -v curl >/dev/null 2>&1 || {
    echo "Error: curl is required for the storage step (URL check). Install curl or set SKIP_STORAGE=1." >&2
    exit 1
  }

  if [[ -z "$cap" ]]; then
    echo "Error: STORAGE_POOL_PROVISIONED_CAPACITY is empty after resolution." >&2
    exit 1
  fi

  if [[ "$cap" =~ ^([0-9]+)GiB$ ]]; then
    gib="${BASH_REMATCH[1]}"
    if (( gib < 10240 )); then
      echo "Error: Hyperdisk Balanced pool minimum capacity is 10240 GiB (10 TiB). Got ${cap}." >&2
      exit 1
    fi
  elif [[ "$cap" =~ ^([0-9]+)TiB$ ]]; then
    tib="${BASH_REMATCH[1]}"
    if (( tib < 10 )); then
      echo "Error: Hyperdisk Balanced pool minimum capacity is 10 TiB. Got ${cap}." >&2
      exit 1
    fi
  else
    echo "Error: STORAGE_POOL_PROVISIONED_CAPACITY must look like 10TiB or 10240GiB (got: ${cap})." >&2
    exit 1
  fi

  if ! [[ "$iops" =~ ^[1-9][0-9]*$ ]] || (( iops % 10000 != 0 )); then
    echo "Error: STORAGE_POOL_PROVISIONED_IOPS must be a positive multiple of 10000 (GCP). Got: ${iops}" >&2
    exit 1
  fi

  if ! [[ "$tp" =~ ^[1-9][0-9]*$ ]] || (( tp < 1024 )) || (( tp % 1024 != 0 )); then
    echo "Error: STORAGE_POOL_PROVISIONED_THROUGHPUT must be MiB/s, at least 1024 (1 GiB/s), in multiples of 1024. Got: ${tp}" >&2
    exit 1
  fi

  echo "  Validating StorageClass manifest (oc apply --dry-run=client)..."
  oc apply --dry-run=client -f - <<EOF >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sp-balanced-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    storageclass.kubevirt.io/is-default-virt-class: "true"
allowVolumeExpansion: true
parameters:
  storage-pools: ${POOL_PATH}
  type: hyperdisk-balanced
provisioner: pd.csi.storage.gke.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

  echo "  Validating VolumeSnapshotClass URL (HTTP HEAD)..."
  curl -sfI --connect-timeout 10 --max-time 30 "$VSC_IMAGES_URL" -o /dev/null || {
    echo "Error: cannot fetch ${VSC_IMAGES_URL} (HEAD). Check network or URL." >&2
    exit 1
  }
}

POOL_PATH="projects/${GCP_PROJECT}/zones/${GCP_ZONE}/storagePools/${STORAGE_POOL_NAME}"

if [[ "$SKIP_STORAGE" != "1" ]]; then
  if [[ -z "$STORAGE_POOL_PROVISIONED_CAPACITY" ]]; then
    if [[ -n "$STORAGE_POOL_CAPACITY_GB" ]]; then
      STORAGE_POOL_PROVISIONED_CAPACITY="${STORAGE_POOL_CAPACITY_GB}GiB"
      echo "  storage pool capacity: ${STORAGE_POOL_PROVISIONED_CAPACITY} (from STORAGE_POOL_CAPACITY_GB; prefer STORAGE_POOL_PROVISIONED_CAPACITY)"
    else
      STORAGE_POOL_PROVISIONED_CAPACITY="10240GiB"
      echo "  storage pool capacity: ${STORAGE_POOL_PROVISIONED_CAPACITY} (default; 10 TiB minimum per GCP)"
    fi
  else
    echo "  storage pool capacity: ${STORAGE_POOL_PROVISIONED_CAPACITY}"
  fi
  echo "  storage pool IOPS=${STORAGE_POOL_PROVISIONED_IOPS} throughput=${STORAGE_POOL_PROVISIONED_THROUGHPUT}MiB/s"
  validate_storage_inputs
  echo "  Storage inputs OK (GCP limits + oc dry-run client + VSC URL)."
fi

# --- Step 1 (optional): Hyperdisk pool + StorageClass + VolumeSnapshotClass -

TOTAL_STEPS=5
[[ "$SKIP_STORAGE" == "1" ]] && TOTAL_STEPS=3
STEP=0

if [[ "$SKIP_STORAGE" != "1" ]]; then
  STEP=$((STEP + 1))
  echo ""
  echo "=== Step ${STEP}/${TOTAL_STEPS}: Hyperdisk pool, StorageClass, VolumeSnapshotClass (before CNV) ==="

  pool_exists=$(gcloud compute storage-pools describe "$STORAGE_POOL_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --format='value(name)' 2>/dev/null || true)

  if [[ -n "$pool_exists" ]]; then
    echo "  Storage pool '${STORAGE_POOL_NAME}' already exists in ${GCP_ZONE}; skipping creation."
  else
    echo "  Creating storage pool '${STORAGE_POOL_NAME}' (type=hyperdisk-balanced, capacity=${STORAGE_POOL_PROVISIONED_CAPACITY}, iops=${STORAGE_POOL_PROVISIONED_IOPS}, throughput=${STORAGE_POOL_PROVISIONED_THROUGHPUT}MiB/s)..."
    gcloud compute storage-pools create "$STORAGE_POOL_NAME" \
      --project="$GCP_PROJECT" \
      --zone="$GCP_ZONE" \
      --storage-pool-type=hyperdisk-balanced \
      --capacity-provisioning-type=advanced \
      --performance-provisioning-type=advanced \
      --provisioned-capacity="${STORAGE_POOL_PROVISIONED_CAPACITY}" \
      --provisioned-iops="${STORAGE_POOL_PROVISIONED_IOPS}" \
      --provisioned-throughput="${STORAGE_POOL_PROVISIONED_THROUGHPUT}"
    echo "  Storage pool created."
  fi

  if oc get storageclass sp-balanced-storage >/dev/null 2>&1; then
    echo "  StorageClass sp-balanced-storage already exists; applying (updates storage-pools if changed)."
  fi

  oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sp-balanced-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    storageclass.kubevirt.io/is-default-virt-class: "true"
allowVolumeExpansion: true
parameters:
  storage-pools: ${POOL_PATH}
  type: hyperdisk-balanced
provisioner: pd.csi.storage.gke.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
  echo "  StorageClass sp-balanced-storage applied."

  echo "  Removing default annotation from standard-csi (if present)..."
  oc annotate storageclass standard-csi storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
  echo "  Default StorageClasses:"
  oc get storageclass -o custom-columns='NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class' | head -10

  echo "  Applying VolumeSnapshotClass csi-gce-pd-vsc-images..."
  oc apply -f "$VSC_IMAGES_URL"
  echo "  VolumeSnapshotClass applied."
fi

# --- Step 2 (or 1 if SKIP_STORAGE): Install CNV operator -------------------

STEP=$((STEP + 1))
echo ""
echo "=== Step ${STEP}/${TOTAL_STEPS}: Install OpenShift Virtualization operator (${CNV_NAMESPACE}) ==="
echo "  (Aligns with OperatorHub: subscription/${CNV_SUBSCRIPTION_NAME}, channel ${CNV_CHANNEL}, package ${CNV_PACKAGE_NAME})"

# Legacy script used metadata.name kubevirt-hyperconverged for the Subscription; product + Hub use hco-operatorhub.
if oc get subscription kubevirt-hyperconverged -n "$CNV_NAMESPACE" -o name >/dev/null 2>&1; then
  echo "  Removing legacy Subscription kubevirt-hyperconverged (wrong name vs OCP doc / OperatorHub)."
  oc delete subscription kubevirt-hyperconverged -n "$CNV_NAMESPACE" 2>/dev/null || true
fi

STARTING_YAML=""
if [[ -n "${CNV_STARTING_CSV}" ]]; then
  STARTING_YAML="  startingCSV: \"${CNV_STARTING_CSV}\""
fi

# OperatorHub creates an OperatorGroup with generateName openshift-cnv-*. Applying a second OG
# (e.g. kubevirt-hyperconverged-group) makes OLM fail the CSV: TooManyOperatorGroups.
OG_COUNT="$(oc get operatorgroup -n "$CNV_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
OG_COUNT="${OG_COUNT:-0}"
if [[ "$OG_COUNT" -gt 1 ]]; then
  echo "Error: namespace ${CNV_NAMESPACE} has ${OG_COUNT} OperatorGroups; OLM sets the CSV to Failed (TooManyOperatorGroups)." >&2
  oc get operatorgroup -n "$CNV_NAMESPACE" -o wide >&2
  echo "Delete the duplicate so exactly one OperatorGroup remains, then retry (e.g. Hub-created openshift-cnv-* vs script kubevirt-hyperconverged-group)." >&2
  exit 1
fi

OG_MANIFEST=""
if [[ "$OG_COUNT" -eq 0 ]]; then
  OG_MANIFEST="$(cat <<OGEOF
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: ${CNV_NAMESPACE}
spec:
  targetNamespaces:
    - ${CNV_NAMESPACE}
OGEOF
)"
  echo "  No OperatorGroup in ${CNV_NAMESPACE}; will create kubevirt-hyperconverged-group."
else
  echo "  OperatorGroup already in ${CNV_NAMESPACE} (${OG_COUNT}); skipping OperatorGroup apply (Hub or prior install)."
fi

CNV_OLM_MANIFEST="$(cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CNV_NAMESPACE}
  labels:
    openshift.io/cluster-monitoring: "true"
${OG_MANIFEST}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${CNV_SUBSCRIPTION_NAME}
  namespace: ${CNV_NAMESPACE}
spec:
  channel: "${CNV_CHANNEL}"
${STARTING_YAML}
  installPlanApproval: Automatic
  name: ${CNV_PACKAGE_NAME}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)"

echo "  Validating CNV OLM manifests (oc apply --dry-run=client)..."
printf '%s\n' "$CNV_OLM_MANIFEST" | oc apply --dry-run=client -f -

printf '%s\n' "$CNV_OLM_MANIFEST" | oc apply -f -

WAIT_SEC="$(wait_timeout_seconds)"
echo "  Waiting for CSV name (currentCSV / CSV list) then Succeeded phase (timeout ${CNV_WAIT_TIMEOUT})..."
CSV_NAME=""
deadline=$((SECONDS + WAIT_SEC))
last_diag="$SECONDS"
while [[ $SECONDS -lt $deadline ]]; do
  CSV_NAME="$(resolve_cnv_csv_name)"
  if [[ -n "$CSV_NAME" ]]; then
    break
  fi
  if [[ $((SECONDS - last_diag)) -ge ${CNV_WAIT_DIAG_INTERVAL_SEC} ]]; then
    echo "  ... still resolving CSV name (~$((deadline - SECONDS))s left on discovery window) ..."
    print_subscription_diag
    last_diag="$SECONDS"
  fi
  sleep 10
done
if [[ -z "$CSV_NAME" ]]; then
  echo "Error: timed out waiting for a kubevirt-hyperconverged CSV (subscription ${CNV_SUBSCRIPTION_NAME} has no currentCSV / no CSV in ${CNV_NAMESPACE})." >&2
  print_subscription_diag
  exit 1
fi
echo "  CSV: ${CSV_NAME}"

oc wait "csv/${CSV_NAME}" -n "$CNV_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout="${CNV_WAIT_TIMEOUT}"
echo "  CNV operator CSV succeeded."

# --- Step 3 (or 2): Create HyperConverged CR -------------------------------

STEP=$((STEP + 1))
echo ""
echo "=== Step ${STEP}/${TOTAL_STEPS}: Create HyperConverged CR ==="

echo "  Validating HyperConverged (oc apply --dry-run=client)..."
oc apply --dry-run=client -f - <<EOF >/dev/null
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: ${CNV_NAMESPACE}
spec: {}
EOF

oc apply -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: ${CNV_NAMESPACE}
spec: {}
EOF

echo "  Waiting for HyperConverged to be Available (timeout ${CNV_WAIT_TIMEOUT})..."
oc wait hyperconverged/kubevirt-hyperconverged -n "$CNV_NAMESPACE" \
  --for=condition=Available \
  --timeout="${CNV_WAIT_TIMEOUT}"
echo "  HyperConverged is Available."

# --- Step 4 (or 3): Verify CNV pods ---------------------------------------

STEP=$((STEP + 1))
echo ""
echo "=== Step ${STEP}/${TOTAL_STEPS}: Verify CNV pods ==="

running=$(oc get pods -n "$CNV_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  ${running} pod(s) in ${CNV_NAMESPACE}"
oc get pods -n "$CNV_NAMESPACE" --no-headers | head -10
if [[ "$running" -gt 10 ]]; then
  echo "  ... ($(( running - 10 )) more)"
fi

if [[ "$SKIP_STORAGE" == "1" ]]; then
  echo ""
  echo "=== deploy-openshift-virt complete (storage skipped) ==="
  exit 0
fi

# --- Step 5: Verify storage + attachment limits ----------------------------

STEP=$((STEP + 1))
echo ""
echo "=== Step ${STEP}/${TOTAL_STEPS}: Verify storage setup ==="

echo "  VolumeSnapshotClass snapshot-type:"
oc get volumesnapshotclass csi-gce-pd-vsc-images -o jsonpath='{.parameters.snapshot-type}' 2>/dev/null && echo "" || echo "  (not found)"

echo ""
echo "  CSINode volume attachment limits:"
oc get csinode -o custom-columns="NAME:.metadata.name,MAX-VOLUMES:.spec.drivers[0].allocatable.count" 2>/dev/null | head -10

echo ""
echo "=== deploy-openshift-virt complete ==="
echo "Storage guide reference: https://github.com/noamasu/docs/blob/main/gcp/gcp-storage-configuration-4.21.md"
