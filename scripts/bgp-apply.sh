#!/usr/bin/env bash
# End-to-end BGP+CUDN deployment: WIF, cluster apply, oc login, configure-routing.sh.
# Dynamic resources (NCC spoke, BGP peers, canIpForward, FRRConfiguration) are managed
# by the operator (operator/) — Terraform only creates static infra.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIF_DIR="${ROOT}/wif_config"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"
# shellcheck source=orchestration-lib.sh
source "${ROOT}/scripts/orchestration-lib.sh"

# Default: skip the long "wait for public CA" loop and non-interactive oc login against
# bootstrap/self-signed API certs. To require system-trusted TLS first, export an empty
# value: OC_LOGIN_EXTRA_ARGS= (must be set in the environment, not merely unset).
if [[ -z "${OC_LOGIN_EXTRA_ARGS+x}" ]]; then
  OC_LOGIN_EXTRA_ARGS='--insecure-skip-tls-verify'
fi

for cmd in terraform oc curl; do
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
# Avoid non-interactive hangs: oc prompts on unknown CA until OCM serves a public chain.
if [[ "${OC_LOGIN_EXTRA_ARGS:-}" != *"--insecure-skip-tls-verify"* ]]; then
  orchestration_wait_api_tls "$API_URL"
fi
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
echo "Next (deploy the operator in-cluster):"
echo "  make bgp.deploy-operator"
echo "  make bgp.e2e"
