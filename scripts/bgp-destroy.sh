#!/usr/bin/env bash
# Tear down cluster_bgp_routing then wif_config (same order as README).
# If you used the in-cluster operator, run `make bgp.destroy-operator` from
# the repo root first — otherwise Cloud Router peers / NCC spoke can block instance delete.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIF_DIR="${ROOT}/wif_config"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"

command -v terraform >/dev/null 2>&1 || {
  echo "Error: terraform not found on PATH." >&2
  exit 1
}

echo "=== bgp.teardown: step 1/2 - Terraform destroy cluster_bgp_routing (${CLUSTER_DIR}) ==="
cd "$CLUSTER_DIR"
terraform init -upgrade
terraform destroy -auto-approve "$@"

echo ""
echo "=== bgp.teardown: step 2/2 - Terraform destroy wif_config (${WIF_DIR}) ==="
cd "$WIF_DIR"
terraform init -upgrade
terraform destroy -auto-approve "$@"

echo ""
echo "=== bgp.teardown: scripts/bgp-destroy.sh finished ==="
echo "If you created OpenShift resources by hand, delete them separately (see README teardown)."
