#!/usr/bin/env bash
# End-to-end BGP+CUDN deployment: WIF, cluster apply, oc login, configure-routing.sh.
# Dynamic resources (NCC spoke, BGP peers, canIpForward, FRRConfiguration) are managed
# by the controller (controller/python/) — Terraform only creates static infra.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIF_DIR="${ROOT}/wif_config"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"
# shellcheck source=orchestration-lib.sh
source "${ROOT}/scripts/orchestration-lib.sh"

OC_LOGIN_EXTRA_ARGS="${OC_LOGIN_EXTRA_ARGS:-}"

for cmd in terraform oc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: required command '$cmd' not found on PATH." >&2
    exit 1
  }
done

echo "=== Step 1/4: WIF config (${WIF_DIR}) ==="
cd "$WIF_DIR"
terraform init -upgrade
terraform apply -auto-approve "$@"

cd "$CLUSTER_DIR"
terraform init -upgrade

echo "=== Step 2/4: Cluster + VPC + BGP static infra ==="
terraform apply -auto-approve \
  -var='enable_bgp_routing=true' \
  -var='enable_echo_client_vm=true' \
  "$@"

echo "=== Step 3/4: oc login ==="
API_URL=$(terraform output -raw api_url)
ADMIN_USER=$(terraform output -raw admin_username)
ADMIN_PASS=$(terraform output -raw admin_password)
# shellcheck disable=SC2086
if ! oc login "$API_URL" -u "$ADMIN_USER" -p "$ADMIN_PASS" $OC_LOGIN_EXTRA_ARGS 2>&1; then
  echo "  Login failed — retrying with --insecure-skip-tls-verify..."
  oc login "$API_URL" -u "$ADMIN_USER" -p "$ADMIN_PASS" --insecure-skip-tls-verify $OC_LOGIN_EXTRA_ARGS
fi

echo "=== Step 4/4: configure-routing.sh (FRR enable, CUDN, RouteAdvertisements) ==="
cd "$CLUSTER_DIR"
./scripts/configure-routing.sh \
  --project "$(terraform output -raw gcp_project_id)" \
  --region "$(terraform output -raw gcp_region)" \
  --cluster "$(terraform output -raw cluster_name)"

echo "=== bgp-apply complete ==="
echo "Deploy the controller (controller/python/) to manage NCC spoke, BGP peers, canIpForward, and FRRConfiguration."
echo "Optional: make bgp-e2e   # or: cd cluster_bgp_routing && ./scripts/deploy-cudn-test-pods.sh"
