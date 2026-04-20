#!/usr/bin/env bash
# Remove Hyperdisk storage created for OpenShift Virtualization on GCP (virt.deploy).
#
# Order matters: GCP refuses storage-pool delete while zonal disks still reference the pool.
# This script deletes CDI/os-images consumers, VolumeSnapshots, PVCs using sp-balanced-storage,
# then VolumeSnapshotClass / StorageClass / default SC restore, then GCP disks in the pool
# (orphans), then the storage pool in virt_storage_zone (bare metal AZ when BM pool is enabled),
# or every availability_zones entry if that output is missing (older Terraform state).
#
# Environment:
#   STORAGE_POOL_NAME        Pool id (default: ocp-virt-pool)
#   SKIP_GCP_POOLS           Set to 1 to skip gcloud storage-pools delete (and GCP disk cleanup)
#   SKIP_CLUSTER_STORAGE     Set to 1 to skip oc deletes (GCP only; e.g. API already gone)
#   VIRT_DESTROY_WAIT_SEC    Max seconds to wait for PVCs to disappear (default: 600)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"
STORAGE_POOL_NAME="${STORAGE_POOL_NAME:-ocp-virt-pool}"
SKIP_GCP_POOLS="${SKIP_GCP_POOLS:-}"
SKIP_CLUSTER_STORAGE="${SKIP_CLUSTER_STORAGE:-}"
VIRT_DESTROY_WAIT_SEC="${VIRT_DESTROY_WAIT_SEC:-600}"
OS_IMAGES_NS="${OS_IMAGES_NS:-openshift-virtualization-os-images}"

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: required command '$cmd' not found on PATH." >&2
    exit 1
  }
done

echo "=== Reading cluster_bgp_routing terraform outputs ==="
cd "$CLUSTER_DIR"
GCP_PROJECT=$(terraform output -raw gcp_project_id)
GCP_REGION=$(terraform output -raw gcp_region)
ZONES=()
virt_zone=$(terraform output -raw virt_storage_zone 2>/dev/null || true)
if [[ -n "$virt_zone" ]]; then
  ZONES=("$virt_zone")
else
  ZONE_JSON=$(terraform output -json availability_zones 2>/dev/null || echo '[]')
  while IFS= read -r z; do
    [[ -n "$z" ]] && ZONES+=("$z")
  done < <(echo "$ZONE_JSON" | jq -r '.[]?')
  if [[ ${#ZONES[@]} -eq 0 ]]; then
    ZONES=("${GCP_REGION}-a")
    echo "  No virt_storage_zone / availability_zones; using ${ZONES[0]}"
  fi
fi

echo "  project=${GCP_PROJECT}  region=${GCP_REGION}  zones=${ZONES[*]}"

count_pvc_for_sc() {
  oc get pvc -A -o json 2>/dev/null | jq "[.items[]? | select(.spec.storageClassName == \"sp-balanced-storage\")] | length" || echo 999
}

count_volumesnapshots() {
  oc get volumesnapshot -A -o json 2>/dev/null | jq '[.items[]?] | length' || echo 999
}

wait_for_pvc_sc_cleared() {
  local elapsed=0
  while [[ $elapsed -lt $VIRT_DESTROY_WAIT_SEC ]]; do
    local n
    n=$(count_pvc_for_sc)
    if [[ "${n}" -eq 0 ]]; then
      return 0
    fi
    echo "  Waiting for PVCs using sp-balanced-storage to finish (${n} remaining, ${elapsed}s/${VIRT_DESTROY_WAIT_SEC}s)..."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "Error: timed out after ${VIRT_DESTROY_WAIT_SEC}s; PVCs still use sp-balanced-storage." >&2
  echo "  Hint: oc get pvc -A --field-selector spec.storageClassName=sp-balanced-storage" >&2
  return 1
}

wait_for_snapshots_cleared() {
  local elapsed=0 max=300
  while [[ $elapsed -lt $max ]]; do
    local n
    n=$(count_volumesnapshots)
    if [[ "${n}" -eq 0 ]]; then
      return 0
    fi
    echo "  Waiting for VolumeSnapshots to finish (${n} remaining)..."
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "  Warning: VolumeSnapshots still present after ${max}s; continuing." >&2
  return 0
}

delete_disks_in_storage_pool_zone() {
  local z=$1
  local json names
  if ! json=$(gcloud compute disks list --project="$GCP_PROJECT" --zones="$z" --format=json 2>/dev/null); then
    return 0
  fi
  names=$(echo "$json" | jq -r --arg pname "$STORAGE_POOL_NAME" \
    '.[]? | select((.storagePool // "") | endswith("/storagePools/" + $pname)) | .name')
  while IFS= read -r disk; do
    [[ -z "${disk:-}" ]] && continue
    echo "  Deleting GCP disk ${disk} in ${z} (still in pool ${STORAGE_POOL_NAME})..."
    gcloud compute disks delete "$disk" --project="$GCP_PROJECT" --zone="$z" --quiet || true
  done <<<"${names}"
}

if [[ "$SKIP_CLUSTER_STORAGE" != "1" ]]; then
  command -v oc >/dev/null 2>&1 || {
    echo "Error: oc not found. Set SKIP_CLUSTER_STORAGE=1 to delete GCP pools/disks only." >&2
    exit 1
  }

  echo ""
  echo "=== Step 1/3: Kubernetes — unprovision volumes, then StorageClass / VolumeSnapshotClass ==="

  echo "  Removing CDI / os-images importers and PVCs that use sp-balanced-storage..."
  if oc get ns "$OS_IMAGES_NS" >/dev/null 2>&1; then
    if oc get crd dataimportcrons.cdi.kubevirt.io >/dev/null 2>&1; then
      oc delete dataimportcron -n "$OS_IMAGES_NS" --all --wait=true --timeout=300s 2>/dev/null || true
    fi
    if oc get crd datavolumes.cdi.kubevirt.io >/dev/null 2>&1; then
      oc delete datavolume -n "$OS_IMAGES_NS" --all --wait=false 2>/dev/null || true
    fi
  fi

  if oc get volumesnapshot -A -o name >/dev/null 2>&1; then
    echo "  Deleting VolumeSnapshots (all namespaces)..."
    oc get volumesnapshot -A -o json 2>/dev/null | jq -r '.items[]? | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r vs_ns vs_name; do
        [[ -n "${vs_ns:-}" ]] || continue
        oc delete "volumesnapshot/${vs_name}" -n "$vs_ns" --wait=false 2>/dev/null || true
      done
    wait_for_snapshots_cleared || true
  fi

  if oc get pvc -A -o json 2>/dev/null | jq -e '.items[]? | select(.spec.storageClassName == "sp-balanced-storage")' >/dev/null 2>&1; then
    echo "  Deleting PVCs bound to sp-balanced-storage (all namespaces)..."
    oc get pvc -A -o json | jq -r '.items[]? | select(.spec.storageClassName == "sp-balanced-storage") | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r pvc_ns pvc_name; do
        [[ -n "${pvc_ns:-}" ]] || continue
        oc delete "pvc/${pvc_name}" -n "$pvc_ns" --wait=false 2>/dev/null || true
      done
    wait_for_pvc_sc_cleared
  else
    echo "  No PVCs using sp-balanced-storage."
  fi

  oc annotate storageclass sp-balanced-storage storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
  oc annotate storageclass sp-balanced-storage storageclass.kubevirt.io/is-default-virt-class- 2>/dev/null || true

  if oc get volumesnapshotclass csi-gce-pd-vsc-images >/dev/null 2>&1; then
    echo "  Deleting VolumeSnapshotClass csi-gce-pd-vsc-images..."
    oc delete volumesnapshotclass csi-gce-pd-vsc-images --ignore-not-found=true --wait=true --timeout=120s 2>/dev/null || {
      echo "  Warning: VolumeSnapshotClass delete failed (snapshots may still reference it)." >&2
    }
  else
    echo "  VolumeSnapshotClass csi-gce-pd-vsc-images not found; skipping."
  fi

  if oc get storageclass sp-balanced-storage >/dev/null 2>&1; then
    echo "  Deleting StorageClass sp-balanced-storage..."
    if ! oc delete storageclass sp-balanced-storage --wait=true --timeout=180s 2>/dev/null; then
      echo "Error: could not delete StorageClass sp-balanced-storage." >&2
      echo "  Try: oc get pvc -A --field-selector spec.storageClassName=sp-balanced-storage" >&2
      exit 1
    fi
  else
    echo "  StorageClass sp-balanced-storage not found; skipping."
  fi

  if oc get storageclass standard-csi >/dev/null 2>&1; then
    echo "  Restoring standard-csi as default StorageClass..."
    oc annotate storageclass standard-csi storageclass.kubernetes.io/is-default-class=true --overwrite=true 2>/dev/null || true
  fi
else
  echo ""
  echo "=== Step 1/3: Skipping Kubernetes (SKIP_CLUSTER_STORAGE=1) ==="
fi

if [[ "$SKIP_GCP_POOLS" != "1" ]]; then
  command -v gcloud >/dev/null 2>&1 || {
    echo "Error: gcloud not found. Set SKIP_GCP_POOLS=1 if pools are already gone." >&2
    exit 1
  }

  echo ""
  echo "=== Step 2/3: GCP — disks in pool, then storage pool(s) ==="
  for z in "${ZONES[@]}"; do
    if gcloud compute storage-pools describe "$STORAGE_POOL_NAME" --project="$GCP_PROJECT" --zone="$z" \
      --format='value(name)' >/dev/null 2>&1; then
      echo "  Zone ${z}: removing disks still assigned to pool ${STORAGE_POOL_NAME}..."
      delete_disks_in_storage_pool_zone "$z"
      echo "  Deleting storage pool ${STORAGE_POOL_NAME} in ${z}..."
      if ! gcloud compute storage-pools delete "$STORAGE_POOL_NAME" --project="$GCP_PROJECT" --zone="$z" --quiet; then
        echo "  Pool delete failed; retrying disk cleanup once..."
        delete_disks_in_storage_pool_zone "$z"
        gcloud compute storage-pools delete "$STORAGE_POOL_NAME" --project="$GCP_PROJECT" --zone="$z" --quiet
      fi
    else
      echo "  No pool '${STORAGE_POOL_NAME}' in ${z} (skip)."
    fi
  done
else
  echo ""
  echo "=== Step 2/3: Skipping GCP pools (SKIP_GCP_POOLS=1) ==="
fi

echo ""
echo "=== Step 3/3: Done ==="
echo "If you use virt.deploy / CNV only: consider openshift-cnv and HyperConverged before full cluster destroy (not handled here)."
