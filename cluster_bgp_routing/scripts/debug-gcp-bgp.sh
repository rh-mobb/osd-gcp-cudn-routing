#!/usr/bin/env bash
set -euo pipefail

# Print gcloud diagnostics for the BGP stack (Cloud Router, NCC spoke, routes, firewalls).
# Run from cluster_bgp_routing/ after terraform apply with enable_bgp_routing=true.
#
# Usage:
#   ./scripts/debug-gcp-bgp.sh [--dir DIR]
#   DIR defaults to the parent of this script (cluster_bgp_routing/).

CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) CLUSTER_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dir PATH_TO_cluster_bgp_routing]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for cmd in terraform jq gcloud; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH." >&2; exit 1; }
done

cd "$CLUSTER_DIR"

TF_JSON="$(terraform output -json)"
if [[ "$(echo "$TF_JSON" | jq -r '.cloud_router_id.value // empty')" == "" ]]; then
  echo "ERROR: terraform output cloud_router_id is empty. Apply with enable_bgp_routing=true." >&2
  exit 1
fi

GCP_PROJECT="$(echo "$TF_JSON" | jq -r '.gcp_project_id.value')"
GCP_REGION="$(echo "$TF_JSON" | jq -r '.gcp_region.value')"
CLUSTER="$(echo "$TF_JSON" | jq -r '.cluster_name.value')"
CUDN_CIDR="$(echo "$TF_JSON" | jq -r '.cudn_cidr.value')"
ROUTER="${CLUSTER}-cudn-cr"
NCC_HUB="${CLUSTER}-ncc-hub"
NCC_SPOKE="${CLUSTER}-ra-spoke"
FW_BGP="${CLUSTER}-bgp-worker-subnet"
FW_CUDN="${CLUSTER}-worker-subnet-to-cudn"

section() {
  printf '\n=== %s ===\n' "$1"
}

section "Terraform (summary)"
echo "$TF_JSON" | jq -r '
  [
    "- gcp_project_id: \(.gcp_project_id.value)",
    "- gcp_region: \(.gcp_region.value)",
    "- cluster_name: \(.cluster_name.value)",
    "- cloud_router_asn (GCP): \(.cloud_router_asn.value)",
    "- frr_asn (nodes): \(.frr_asn.value)",
    "- cudn_cidr: \(.cudn_cidr.value)",
    "- cloud_router_interface_ips: \(.cloud_router_interface_ips.value | @json)"
  ] | .[]'
echo "$TF_JSON" | jq -r '.bgp_peer_matrix.value[] | "- worker \(.instance_name): \(.worker_ip_address) peers \(.cloud_router_ips | @json)"'

section "Cloud Router BGP status ($ROUTER)"
gcloud compute routers get-status "$ROUTER" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" --format=yaml

section "Cloud Router ($ROUTER)"
gcloud compute routers describe "$ROUTER" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" --format=yaml

section "NCC hub ($NCC_HUB)"
gcloud network-connectivity hubs describe "$NCC_HUB" \
  --project="$GCP_PROJECT" --format=yaml

section "NCC spoke ($NCC_SPOKE, $GCP_REGION)"
gcloud network-connectivity spokes describe "$NCC_SPOKE" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" --format=yaml

section "VPC routes (dest $CUDN_CIDR)"
ROUTE_COUNT="$(gcloud compute routes list --project="$GCP_PROJECT" \
  --filter="destRange=$CUDN_CIDR" \
  --format="value(name)" 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "$ROUTE_COUNT" == "0" ]]; then
  echo "(no routes with destRange=$CUDN_CIDR — expect at least one dynamic route when BGP is established)"
else
  gcloud compute routes list --project="$GCP_PROJECT" \
    --filter="destRange=$CUDN_CIDR" \
    --format="table(name,destRange,priority,nextHopIp,nextHopPeering)"
fi

section "Firewall: $FW_BGP"
gcloud compute firewall-rules describe "$FW_BGP" \
  --project="$GCP_PROJECT" \
  --format="yaml(name,direction,sourceRanges,destinationRanges,allowed,priority,disabled)"

section "Firewall: $FW_CUDN"
if gcloud compute firewall-rules describe "$FW_CUDN" \
  --project="$GCP_PROJECT" \
  --format="yaml(name,direction,sourceRanges,destinationRanges,allowed,priority,disabled,targetTags)" 2>/dev/null; then
  :
else
  echo "(rule not found — e.g. worker_subnet_to_cudn_firewall_mode=none or renamed)"
fi

section "Done"
