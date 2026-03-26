#!/usr/bin/env bash
set -euo pipefail

# Post-deploy configuration for BGP-based CUDN routing on OSD-GCP (NCC + Cloud Router).
#
# Run AFTER:
#   1. terraform apply (cluster + BGP routing are up; enable_bgp_routing=true)
#   2. oc login to the cluster
#
# Run from cluster_bgp_routing/ so terraform output works.
#
# This script:
#   - Enables canIpForward on machine-pool workers
#   - Enables FRR + route advertisements (oc patch)
#   - Creates CUDN namespace, ClusterUserDefinedNetwork
#   - Creates one FRRConfiguration per worker, each peering to both Cloud Router interface IPs
#   - Creates RouteAdvertisements (frrConfigurationSelector matches all FRR configs)
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
CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

for cmd in oc gcloud jq terraform; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH." >&2; exit 1; }
done

echo "=== BGP / CUDN Routing Configuration ==="
echo "Project:   $GCP_PROJECT"
echo "Region:    $GCP_REGION"
echo "Cluster:   $CLUSTER_NAME"
echo "CUDN name: $CUDN_NAME"
echo "CUDN CIDR: $CUDN_CIDR"
echo "Namespace: $CUDN_NAMESPACE"
echo ""

CLOUD_ROUTER_ASN="$(cd "$CLUSTER_DIR" && terraform output -raw cloud_router_asn)"
FRR_ASN="$(cd "$CLUSTER_DIR" && terraform output -raw frr_asn)"
BGP_MATRIX_JSON="$(cd "$CLUSTER_DIR" && terraform output -json bgp_peer_matrix)"

if [[ "$BGP_MATRIX_JSON" == "[]" ]]; then
  echo "ERROR: terraform output bgp_peer_matrix is empty. Apply with enable_bgp_routing=true and running workers." >&2
  exit 1
fi

# --- Step 1: canIpForward ---
WORKER_ZONE="$(cd "$CLUSTER_DIR" && terraform output -raw availability_zone)"
"$CLUSTER_DIR/scripts/enable-worker-can-ip-forward.sh" \
  --project "$GCP_PROJECT" \
  --zone "$WORKER_ZONE" \
  --cluster "$CLUSTER_NAME"
echo ""

# --- Step 2: FRR + route advertisements ---
echo "--- Step 2: Enabling FRR and route advertisements ---"
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

# --- Step 3: Namespace ---
echo "--- Step 3: Creating CUDN namespace '$CUDN_NAMESPACE' ---"
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

# --- Step 4: CUDN ---
echo "--- Step 4: Creating ClusterUserDefinedNetwork ---"
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

# --- Step 5: Per-node FRRConfiguration (two Cloud Router neighbors each — primary + redundant) ---
echo "--- Step 5: Applying per-worker FRRConfiguration (BGP to both Cloud Router interfaces) ---"
oc delete frrconfiguration -n openshift-frr-k8s -l cudn.redhat.com/bgp-stack=osd-gcp-bgp --ignore-not-found=true

NODES_JSON=$(oc get nodes -o json)

while IFS= read -r row; do
  INST_NAME=$(echo "$row" | jq -r '.instance_name')
  NODE_NAME=$(echo "$NODES_JSON" | jq -r --arg inst "$INST_NAME" \
    '.items[] | select(.spec.providerID != null and (.spec.providerID | split("/") | last == $inst)) | .metadata.name' | head -1)

  if [[ -z "$NODE_NAME" || "$NODE_NAME" == "null" ]]; then
    echo "ERROR: No node found for GCE instance '$INST_NAME' (providerID suffix match)." >&2
    exit 1
  fi

  SAFE_NAME=$(echo "$INST_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-50)
  FRR_NAME="bgp-${SAFE_NAME}"

  # Build a neighbor entry for each Cloud Router interface IP (primary + redundant).
  # GCP workers usually have a /32 on br-ex; the peer is reachable via default route only.
  # FRR then reports "No path to specified Neighbor" (BGP Active) while host `nc` to :179
  # still works. We append disable-connected-check via spec.raw — setting ebgpMultiHop on the
  # typed neighbors conflicts with MetalLB admission when merged with ovnk-generated-* objects.
  NEIGHBORS_YAML=""
  FRR_RAW_BLOCK="      router bgp ${FRR_ASN}"
  while IFS= read -r cr_ip; do
    NEIGHBORS_YAML="${NEIGHBORS_YAML}
      - address: ${cr_ip}
        asn: ${CLOUD_ROUTER_ASN}
        disableMP: true
        toReceive:
          allowed:
            mode: all"
    FRR_RAW_BLOCK="${FRR_RAW_BLOCK}"$'\n'"       neighbor ${cr_ip} disable-connected-check"
  done < <(echo "$row" | jq -r '.cloud_router_ips[]')

  echo "  FRRConfiguration $FRR_NAME -> node $NODE_NAME (instance $INST_NAME) neighbors $(echo "$row" | jq -c '.cloud_router_ips')"

  oc apply -f - <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: ${FRR_NAME}
  namespace: openshift-frr-k8s
  labels:
    cudn.redhat.com/bgp-stack: osd-gcp-bgp
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: ${NODE_NAME}
  bgp:
    routers:
    - asn: ${FRR_ASN}
      neighbors:${NEIGHBORS_YAML}
  raw:
    priority: 20
    rawConfig: |
${FRR_RAW_BLOCK}
EOF
done < <(echo "$BGP_MATRIX_JSON" | jq -c '.[]')
echo ""

# --- Step 6: RouteAdvertisements ---
echo "--- Step 6: Creating RouteAdvertisements ---"
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

echo "=== Configuration complete ==="
echo "Optional — from repo root: make bgp-e2e"
echo "Or pods only: ./scripts/deploy-cudn-test-pods.sh -n ${CUDN_NAMESPACE}"
