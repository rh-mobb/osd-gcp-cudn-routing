#!/usr/bin/env bash
set -euo pipefail

# Post-deploy configuration for ILB-based pod network routing on OSD-GCP.
#
# Run this AFTER:
#   1. terraform apply (cluster + ILB routing are up)
#   2. oc login to the cluster
#
# This script:
#   - Enables canIpForward on machine-pool worker nodes only (GCE API; name contains "-worker-")
#   - Enables FRR + route advertisements on the cluster (oc patch)
#   - Creates CUDN namespace, ClusterUserDefinedNetwork, stub FRRConfiguration, then RouteAdvertisements
#   - FRRConfiguration must exist before RouteAdvertisements (OVN needs a base config to merge); use
#     frrConfigurationSelector: {} to match all FRRConfigurations (same pattern as Red Hat route-ad docs)
#
# Usage:
#   ./configure-routing.sh --project PROJECT --region REGION --cluster CLUSTER [--cudn-cidr CIDR] [--cudn-name NAME] [--namespace NS]

# --- Defaults ---
CUDN_CIDR="10.100.0.0/16"
# Must match ClusterUserDefinedNetwork metadata.name; OVN uses the same name for the host VRF when len < 16.
CUDN_NAME="ilb-routing-cudn"
CUDN_NAMESPACE="cudn1"
GCP_PROJECT=""
GCP_REGION=""
CLUSTER_NAME=""

# --- Parse arguments ---
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
  echo "Usage: $0 --project PROJECT --region REGION --cluster CLUSTER [--cudn-cidr CIDR] [--cudn-name NAME] [--namespace NS]"
  exit 1
fi

echo "=== ILB Routing Configuration ==="
echo "Project:   $GCP_PROJECT"
echo "Region:    $GCP_REGION"
echo "Cluster:   $CLUSTER_NAME"
echo "CUDN name: $CUDN_NAME"
echo "CUDN CIDR: $CUDN_CIDR"
echo "Namespace: $CUDN_NAMESPACE"
echo ""

# --- Step 1: Enable canIpForward on worker instances ---
# gcloud compute instances update does not have a --can-ip-forward flag.
# The only way to set canIpForward on an existing instance is via the
# export/update-from-file workflow. canIpForward is a REFRESH-level
# property so no instance restart is required.
echo "--- Step 1: Enabling canIpForward on worker instances (machine pool only) ---"

# Same scope as ILB discovery: cluster name substring, then only names with "-worker-"
# (masters/infra must not get canIpForward for this flow).
RAW_LIST=$(gcloud compute instances list \
  --project="$GCP_PROJECT" \
  --filter="zone:($GCP_REGION) AND status=RUNNING AND name:${CLUSTER_NAME}" \
  --format="json(name,zone)" 2>/dev/null) || RAW_LIST="[]"
[[ -z "$RAW_LIST" ]] && RAW_LIST="[]"

# Use @tsv (not @csv): CSV quoting leaves literal " on zone/name and breaks gcloud --zone.
WORKER_INSTANCES=$(echo "$RAW_LIST" | jq -r \
  '.[] | select(.name | test("-worker-")) | [.name, (.zone | split("/") | last)] | @tsv')

if [[ -z "$WORKER_INSTANCES" ]]; then
  echo "WARNING: No running worker instances found (name~${CLUSTER_NAME} and name contains \"-worker-\")."
  echo "You may need to enable canIpForward manually on workers."
else
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  while IFS=$'\t' read -r INSTANCE_NAME INSTANCE_ZONE; do
    INST_FILE="$TMPDIR/${INSTANCE_NAME}.yaml"
    echo "  Exporting $INSTANCE_NAME ($INSTANCE_ZONE)..."
    gcloud compute instances export "$INSTANCE_NAME" \
      --project="$GCP_PROJECT" \
      --zone="$INSTANCE_ZONE" \
      --destination="$INST_FILE"

    if grep -q "^canIpForward: true" "$INST_FILE"; then
      echo "  canIpForward already enabled on $INSTANCE_NAME, skipping."
      continue
    fi

    if grep -q "^canIpForward:" "$INST_FILE"; then
      sed -i.bak 's/^canIpForward: false/canIpForward: true/' "$INST_FILE"
    else
      echo "canIpForward: true" >> "$INST_FILE"
    fi

    echo "  Updating $INSTANCE_NAME with canIpForward: true..."
    gcloud compute instances update-from-file "$INSTANCE_NAME" \
      --project="$GCP_PROJECT" \
      --zone="$INSTANCE_ZONE" \
      --source="$INST_FILE" \
      --most-disruptive-allowed-action=REFRESH
  done <<< "$WORKER_INSTANCES"
  echo "  Done."
fi
echo ""

# --- Step 2: Enable FRR + route advertisements ---
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
    echo "  WARNING: Timed out waiting for openshift-frr-k8s namespace (5 min)."
    echo "  The namespace may still be creating. Check with: oc get ns openshift-frr-k8s"
  fi
  sleep 10
done

echo "  Waiting for frr-k8s pods..."
sleep 15
oc get pods -n openshift-frr-k8s --no-headers 2>/dev/null || true
echo ""

# --- Step 3: Create CUDN namespace ---
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

# --- Step 4: Create ClusterUserDefinedNetwork ---
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

# --- Step 5: Create stub FRRConfiguration (before RouteAdvertisements) ---
# OVN-K uses FRRConfiguration as a template: it iterates over routers and their neighbors, sets
# toAdvertise with the CUDN prefixes, and generates per-node FRRConfigurations. The template MUST
# have at least one neighbor (with disableMP: true) or OVN-K skips the router entirely.
# For ILB-only routing (no real BGP), we use an RFC 5737 TEST-NET address (192.0.2.1) as a dummy
# neighbor. The BGP session won't establish, but OVN-K still applies the side-effects we need:
# conditional SNAT and OVS ingress flows for the CUDN CIDR.
# nodeSelector: {} — all nodes. No explicit VRF — default VRF is "" internally.
echo "--- Step 5: Creating stub FRRConfiguration ---"

oc apply -f - <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: stub-config
  namespace: openshift-frr-k8s
spec:
  nodeSelector: {}
  bgp:
    routers:
    - asn: 65003
      neighbors:
      - address: 192.0.2.1
        asn: 65003
        disableMP: true
EOF
echo ""

# --- Step 6: Create RouteAdvertisements ---
# nodeSelector: {} required when PodNetwork is advertised (API validation rule).
# frrConfigurationSelector: {} matches our stub. Do NOT set targetVRF — OVN-K represents
# the default VRF as "" (empty string); the string "default" causes a VRF mismatch.
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

# --- Done ---
echo "=== Configuration complete ==="
echo ""
echo "Optional — CUDN e2e (netshoot + icanhazip + ping/curl checks), from repo root:"
echo "  make ilb.e2e"
echo "Or deploy pods only from cluster_ilb_routing/: ./scripts/deploy-cudn-test-pods.sh -n ${CUDN_NAMESPACE}"
echo ""
