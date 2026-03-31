#!/usr/bin/env bash
# Phase 1 baseline for references/fix-bgp-ra.md: confirm symptoms and cluster/GCP truth.
# Does not change the cluster. Exit criteria: you can name BGP router nodes and RA nodeSelector.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${REPO_ROOT}/cluster_bgp_routing"
ROUTER_LABEL="node-role.kubernetes.io/bgp-router"
RUN_E2E=0
SKIP_GCP=0

usage() {
  cat <<'EOF'
Usage: bgp-phase1-baseline.sh [-C DIR] [--e2e] [--skip-gcp]

  Phase 1 baseline (references/fix-bgp-ra.md): cluster + GCP checks only; no changes.

  -C, --cluster-dir DIR   Terraform root (default: <repo>/cluster_bgp_routing)
  --e2e                   Run e2e-cudn-connectivity.sh first (symptom check)
  --skip-gcp              Skip debug-gcp-bgp.sh (oc-only; print hint instead)
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C | --cluster-dir)
      CLUSTER_DIR="$2"
      shift 2
      ;;
    --e2e)
      RUN_E2E=1
      shift
      ;;
    --skip-gcp)
      SKIP_GCP=1
      shift
      ;;
    -h | --help)
      usage 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage 1
      ;;
  esac
done

CLUSTER_DIR="$(cd "$CLUSTER_DIR" && pwd)"

for cmd in oc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '$cmd' not found on PATH." >&2
    exit 1
  }
done

if ! oc whoami &>/dev/null; then
  echo "ERROR: not logged in — run oc login." >&2
  exit 1
fi

section() {
  printf '\n=== %s ===\n' "$1"
}

if [[ "$RUN_E2E" -eq 1 ]]; then
  section "Phase 1 — Symptom check (e2e)"
  bash "${REPO_ROOT}/scripts/e2e-cudn-connectivity.sh" -C "$CLUSTER_DIR"
fi

section "Cluster — nodes labeled ${ROUTER_LABEL}"
oc get nodes -l "${ROUTER_LABEL}" -o wide 2>/dev/null || true
ROUTER_COUNT="$(oc get nodes -l "${ROUTER_LABEL}" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
echo "Router-labeled worker count: ${ROUTER_COUNT}"

section "Cluster — RouteAdvertisements default (spec.nodeSelector)"
if ! oc get routeadvertisements default &>/dev/null; then
  echo "WARN: RouteAdvertisements/default not found (configure-routing.sh not applied?)." >&2
else
  printf 'spec.nodeSelector (jsonpath): '
  oc get routeadvertisements default -o jsonpath='{.spec.nodeSelector}{"\n"}' 2>/dev/null || true
  echo "--- RouteAdvertisements/default (yaml) ---"
  oc get routeadvertisements default -o yaml
fi

section "Cluster — FRRConfiguration (openshift-frr-k8s)"
oc get frrconfiguration -n openshift-frr-k8s -o wide 2>/dev/null || {
  echo "WARN: no FRRConfiguration or namespace not ready." >&2
}

section "Phase 1 summary (exit criteria)"
echo "BGP peers (NCC spoke / Cloud Router) are the nodes with label ${ROUTER_LABEL} (see table above)."
RA_SEL="$(oc get routeadvertisements default -o jsonpath='{.spec.nodeSelector}' 2>/dev/null || true)"
if [[ -z "$RA_SEL" || "$RA_SEL" == "{}" ]]; then
  echo "RouteAdvertisements nodeSelector: empty or {} — all nodes in scope for generated FRR behavior; with PodNetwork ads OVN-K requires {} (references/fix-bgp-ra.md Phase 2)."
else
  echo "RouteAdvertisements nodeSelector: ${RA_SEL}"
fi

if [[ "$SKIP_GCP" -eq 1 ]]; then
  echo ""
  echo "Skipped GCP section (--skip-gcp). For CUDN route next hops run:"
  echo "  ${CLUSTER_DIR}/scripts/debug-gcp-bgp.sh --dir ${CLUSTER_DIR}"
  exit 0
fi

section "GCP — debug-gcp-bgp.sh (next hops vs router InternalIPs)"
for cmd in terraform jq gcloud; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '$cmd' not found; use --skip-gcp or install deps." >&2
    exit 1
  }
done

bash "${CLUSTER_DIR}/scripts/debug-gcp-bgp.sh" --dir "$CLUSTER_DIR"

section "Done"
echo "Compare VPC routes (dest CUDN CIDR) nextHopIp values to InternalIP of router-labeled nodes."
if [[ "$RUN_E2E" -eq 0 ]]; then
  echo "Optional symptom check: from repo root, make bgp.e2e"
fi
