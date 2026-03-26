#!/usr/bin/env bash
set -euo pipefail

# BGP stack: same as ILB discovery plus name and primary internal IP (networkIP)
# for NCC router appliance and Cloud Router BGP peers.
#
# Called by Terraform data.external; returns JSON { "instances": "[...]" }.

eval "$(jq -r '@sh "PROJECT=\(.project) ZONE=\(.zone) CLUSTER_NAME=\(.cluster_name)"')"

if ! RAW_LIST=$(gcloud compute instances list \
  --project="$PROJECT" \
  --zones="$ZONE" \
  --filter="status=RUNNING AND name:${CLUSTER_NAME}" \
  --format="json(name,selfLink,zone,networkInterfaces)" 2>/dev/null); then
  RAW_LIST="[]"
fi
[[ -z "$RAW_LIST" ]] && RAW_LIST="[]"

INSTANCES=$(echo "$RAW_LIST" | jq -c \
  'if type == "array" then . else [] end
   | map(select((.name // "") | test("-worker-")))
   | map({
       name: .name,
       selfLink,
       zone,
       networkIP: (.networkInterfaces[0].networkIP // "")
     })')

jq -n --arg instances "$INSTANCES" '{"instances": $instances}'
