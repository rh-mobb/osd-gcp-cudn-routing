#!/usr/bin/env bash
# Log in to the OSD cluster using credentials from cluster_bgp_routing/ Terraform outputs.
# Retries until success or OC_LOGIN_RETRY_MAX_SEC (default 600s).
# Same OC_LOGIN_EXTRA_ARGS / OC_LOGIN_RETRY_* env vars as bgp-apply.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"
# shellcheck source=orchestration-lib.sh
source "${ROOT}/scripts/orchestration-lib.sh"

if [[ -z "${OC_LOGIN_EXTRA_ARGS+x}" ]]; then
  OC_LOGIN_EXTRA_ARGS='--insecure-skip-tls-verify'
fi

for cmd in terraform oc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: required command '$cmd' not found on PATH." >&2
    exit 1
  }
done

cd "$CLUSTER_DIR"
API_URL=$(terraform output -raw api_url)
ADMIN_USER=$(terraform output -raw admin_username)
ADMIN_PASS=$(terraform output -raw admin_password)

if [[ "${OC_LOGIN_EXTRA_ARGS:-}" != *"--insecure-skip-tls-verify"* ]]; then
  orchestration_wait_api_tls "$API_URL"
fi

orchestration_retry_oc_login "$API_URL" "$ADMIN_USER" "$ADMIN_PASS"
