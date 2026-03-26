#!/usr/bin/env bash
set -euo pipefail

# Set GCE canIpForward=true on machine-pool workers (-worker- in name).
# Required before creating google_network_connectivity_spoke (router appliance).
#
# Usage:
#   ./enable-worker-can-ip-forward.sh --project PROJECT --zone ZONE --cluster CLUSTER

GCP_PROJECT=""
GCP_ZONE=""
CLUSTER_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)  GCP_PROJECT="$2"; shift 2 ;;
    --zone)     GCP_ZONE="$2"; shift 2 ;;
    --cluster)  CLUSTER_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --project PROJECT --zone ZONE --cluster CLUSTER"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$GCP_PROJECT" || -z "$GCP_ZONE" || -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: --project, --zone, and --cluster are required." >&2
  exit 1
fi

command -v gcloud >/dev/null 2>&1 || { echo "ERROR: 'gcloud' not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: 'jq' not found on PATH." >&2; exit 1; }

echo "--- Enabling canIpForward on worker instances ---"
RAW_LIST=$(gcloud compute instances list \
  --project="$GCP_PROJECT" \
  --zones="$GCP_ZONE" \
  --filter="status=RUNNING AND name:${CLUSTER_NAME}" \
  --format="json(name,zone)" 2>/dev/null) || RAW_LIST="[]"
[[ -z "$RAW_LIST" ]] && RAW_LIST="[]"

WORKER_INSTANCES=$(echo "$RAW_LIST" | jq -r \
  '.[] | select(.name | test("-worker-")) | [.name, (.zone | split("/") | last)] | @tsv')

if [[ -z "$WORKER_INSTANCES" ]]; then
  echo "WARNING: No running worker instances found in zone ${GCP_ZONE}."
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
while IFS=$'\t' read -r INSTANCE_NAME INSTANCE_ZONE; do
  INST_FILE="$TMPDIR/${INSTANCE_NAME}.yaml"
  gcloud compute instances export "$INSTANCE_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$INSTANCE_ZONE" \
    --destination="$INST_FILE"
  if grep -q "^canIpForward: true" "$INST_FILE"; then
    echo "  canIpForward already enabled on $INSTANCE_NAME"
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
