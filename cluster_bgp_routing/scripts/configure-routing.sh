#!/usr/bin/env bash
set -euo pipefail

# One-time post-deploy configuration for BGP-based CUDN routing on OSD-GCP.
# Dynamic resources (canIpForward, NCC spoke, BGP peers, FRRConfiguration) are
# managed by the controller — this script only handles the static Kubernetes setup.
#
# Run AFTER:
#   1. terraform apply with enable_bgp_routing=true — this finishes the *static* GCP
#      side (NCC hub, Cloud Router + interfaces, firewalls). Spoke, BGP peers, and
#      FRRConfiguration CRs are NOT from Terraform; the controller creates them next.
#   2. oc login to the cluster
#
# Run BEFORE the BGP routing controller: this script enables the FRR operator and
# applies CUDN / RouteAdvertisements so FRRConfiguration CRs (controller-managed)
# are reconciled and route advertisement can work.
#
# RouteAdvertisements: when advertisements include PodNetwork, OVN-K validating admission
# requires spec.nodeSelector: {} (pod network must be advertised from all nodes). See
# references/fix-bgp-ra.md Phase 2 — narrowing nodeSelector with PodNetwork is rejected.
#
# Run from anywhere; only `oc` is required on PATH.
#
# This script:
#   - Enables FRR + route advertisements (oc patch)
#   - Creates CUDN namespace, ClusterUserDefinedNetwork
#   - Creates RouteAdvertisements (nodeSelector: {} required with PodNetwork; frrConfigurationSelector {})
#
# Usage:
#   ./configure-routing.sh --project PROJECT --region REGION --cluster CLUSTER \
#     [--cudn-cidr CIDR] [--cudn-name NAME] [--namespace NS]

CUDN_CIDR="10.100.0.0/16"
CUDN_NAME="bgp-routing-cudn"
CUDN_NAMESPACE="cudn1"
GCP_PROJECT=""
GCP_REGION=""
CLUSTER_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    GCP_PROJECT="$2"; shift 2 ;;
    --region)     GCP_REGION="$2"; shift 2 ;;
    --cluster)    CLUSTER_NAME="$2"; shift 2 ;;
    --cudn-cidr)  CUDN_CIDR="$2"; shift 2 ;;
    --cudn-name)   CUDN_NAME="$2"; shift 2 ;;
    --namespace)  CUDN_NAMESPACE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --project PROJECT --region REGION --cluster CLUSTER [--cudn-cidr CIDR] [--cudn-name NAME] [--namespace NS]"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$GCP_PROJECT" || -z "$GCP_REGION" || -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: --project, --region, and --cluster are required."
  exit 1
fi

for cmd in oc; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH." >&2; exit 1; }
done

echo "=== BGP / CUDN One-Time Routing Configuration ==="
echo "Project:   $GCP_PROJECT"
echo "Region:    $GCP_REGION"
echo "Cluster:   $CLUSTER_NAME"
echo "CUDN name: $CUDN_NAME"
echo "CUDN CIDR: $CUDN_CIDR"
echo "Namespace: $CUDN_NAMESPACE"
echo ""

# --- Step 1: FRR + route advertisements ---
echo "--- Step 1: Enabling FRR and route advertisements ---"
oc patch Network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]},"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'

echo "  Waiting for openshift-frr-k8s namespace..."
for i in $(seq 1 30); do
  if oc get namespace openshift-frr-k8s &>/dev/null; then
    echo "  openshift-frr-k8s namespace is ready."
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "  WARNING: Timed out waiting for openshift-frr-k8s namespace."
  fi
  sleep 10
done
sleep 15
oc get pods -n openshift-frr-k8s --no-headers 2>/dev/null || true
echo ""

# --- Step 2: Namespace ---
echo "--- Step 2: Creating CUDN namespace '$CUDN_NAMESPACE' ---"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
    cluster-udn: prod
  name: ${CUDN_NAMESPACE}
EOF
echo ""

# --- Step 3: CUDN ---
echo "--- Step 3: Creating ClusterUserDefinedNetwork ---"
oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${CUDN_NAME}
  labels:
    advertise: "true"
spec:
  namespaceSelector:
    matchLabels:
      cluster-udn: prod
  network:
    layer2:
      ipam:
        lifecycle: Persistent
      role: Primary
      subnets:
      - ${CUDN_CIDR}
    topology: Layer2
EOF
echo ""

# --- Step 4: RouteAdvertisements ---
# nodeSelector: {} is required when PodNetwork is advertised (OVN-K validating webhook).
echo "--- Step 4: Creating RouteAdvertisements ---"
oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: default
spec:
  advertisements:
  - PodNetwork
  nodeSelector: {}
  frrConfigurationSelector: {}
  networkSelectors:
  - networkSelectionType: ClusterUserDefinedNetworks
    clusterUserDefinedNetworkSelector:
      networkSelector:
        matchLabels:
          advertise: "true"
EOF
echo ""

echo "=== One-time configuration complete ==="
echo "Deploy the controller (controller/python/) to manage canIpForward, NCC spoke, BGP peers, and FRRConfiguration."
echo "Optional — from repo root: make bgp.e2e"
echo "Or pods only: ./scripts/deploy-cudn-test-pods.sh -n ${CUDN_NAMESPACE}"
