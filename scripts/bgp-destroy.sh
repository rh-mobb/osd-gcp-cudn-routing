#!/usr/bin/env bash
# Tear down cluster_bgp_routing then wif_config (same order as README).
# If you used the BGP controller, run `make controller.cleanup` from the repo
# root first — otherwise Cloud Router peers / NCC spoke can block instance delete.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIF_DIR="${ROOT}/wif_config"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"

command -v terraform >/dev/null 2>&1 || {
  echo "Error: terraform not found on PATH." >&2
  exit 1
}

echo "=== Destroy cluster stack (${CLUSTER_DIR}) ==="
cd "$CLUSTER_DIR"
terraform init -upgrade
terraform destroy -auto-approve "$@"

echo "=== Destroy WIF (${WIF_DIR}) ==="
cd "$WIF_DIR"
terraform init -upgrade
terraform destroy -auto-approve "$@"

echo "=== bgp-destroy complete ==="
echo "If you created OpenShift resources by hand, delete them separately (see README teardown)."
