#!/usr/bin/env bash
set -euo pipefail

# Called by Terraform's data "external" to discover worker instance
# self-links. Reads project, zone, and cluster_name from stdin JSON,
# returns a JSON object with an "instances" key containing a
# JSON-encoded list.
#
# Only OSD machine-pool worker nodes are included (name contains
# "-worker-"). Masters and infra nodes live on other subnets and must
# not be added to the ILB instance group.
#
# We filter workers with jq after gcloud list. Relying on multiple
# gcloud name~ regex clauses is fragile and can fail silently (exit
# non-zero -> empty list) when combined with 2>/dev/null.

eval "$(jq -r '@sh "PROJECT=\(.project) ZONE=\(.zone) CLUSTER_NAME=\(.cluster_name)"')"

# Use name:CLUSTER for substring match (avoids RE2 edge cases with hyphens in name~ regex).
if ! RAW_LIST=$(gcloud compute instances list \
  --project="$PROJECT" \
  --zones="$ZONE" \
  --filter="status=RUNNING AND name:${CLUSTER_NAME}" \
  --format="json(name,selfLink,zone)" 2>/dev/null); then
  RAW_LIST="[]"
fi
[[ -z "$RAW_LIST" ]] && RAW_LIST="[]"

# jq: keep only machine-pool workers (name contains "-worker-"), output shape unchanged for Terraform
INSTANCES=$(echo "$RAW_LIST" | jq -c \
  'if type == "array" then . else [] end
   | map(select((.name // "") | test("-worker-")))
   | map({selfLink, zone})')

jq -n --arg instances "$INSTANCES" '{"instances": $instances}'
