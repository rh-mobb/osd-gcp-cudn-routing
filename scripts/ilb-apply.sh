#!/usr/bin/env bash
# End-to-end ILB+CUDN deployment: WIF, cluster (pass 1), wait for workers,
# cluster (pass 2 with ILB + echo VM), oc login, configure-routing.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIF_DIR="${ROOT}/wif_config"
CLUSTER_DIR="${ROOT}/cluster_ilb_routing"
# shellcheck source=orchestration-lib.sh
source "${ROOT}/scripts/orchestration-lib.sh"

ILB_APPLY_WORKER_WAIT_ATTEMPTS="${ILB_APPLY_WORKER_WAIT_ATTEMPTS:-60}"
ILB_APPLY_WORKER_WAIT_SLEEP="${ILB_APPLY_WORKER_WAIT_SLEEP:-30}"
ILB_APPLY_MIN_WORKERS="${ILB_APPLY_MIN_WORKERS:-1}"
OC_LOGIN_EXTRA_ARGS="${OC_LOGIN_EXTRA_ARGS:-}"

for cmd in terraform oc gcloud jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: required command '$cmd' not found on PATH." >&2
    exit 1
  }
done

wait_for_workers() {
  local project="$1" zone="$2" cluster="$3"
  local i raw_list n
  for ((i = 1; i <= ILB_APPLY_WORKER_WAIT_ATTEMPTS; i++)); do
    if ! raw_list=$(gcloud compute instances list \
      --project="$project" \
      --zones="$zone" \
      --filter="status=RUNNING AND name:${cluster}" \
      --format="json(name,selfLink,zone)" 2>/dev/null); then
      raw_list="[]"
    fi
    [[ -z "$raw_list" ]] && raw_list="[]"
    n=$(echo "$raw_list" | jq '[.[]? | select((.name // "") | test("-worker-"))] | length')
    if [[ "$n" -ge "$ILB_APPLY_MIN_WORKERS" ]]; then
      echo "Found ${n} running worker VM(s) (need >= ${ILB_APPLY_MIN_WORKERS})."
      return 0
    fi
    echo "Waiting for workers: have ${n}, need >= ${ILB_APPLY_MIN_WORKERS} (attempt ${i}/${ILB_APPLY_WORKER_WAIT_ATTEMPTS}, sleep ${ILB_APPLY_WORKER_WAIT_SLEEP}s)..."
    sleep "$ILB_APPLY_WORKER_WAIT_SLEEP"
  done
  echo "Error: timed out waiting for worker VMs. Check gcloud compute instances list and cluster_ilb_routing variables." >&2
  exit 1
}

echo "=== Step 1/6: WIF config (${WIF_DIR}) ==="
cd "$WIF_DIR"
terraform init -upgrade
terraform apply -auto-approve "$@"

cd "$CLUSTER_DIR"
terraform init -upgrade
if orchestration_force_pass1; then
  echo "=== Step 2/6: Cluster + VPC — first apply (ILB off) (ORCHESTRATION_FORCE_PASS1 set) ==="
  terraform apply -auto-approve "$@"
elif tf_state_counted_module_present "$CLUSTER_DIR" "ilb_routing"; then
  echo "=== Step 2/6: Skipped — module.ilb_routing already in Terraform state ==="
  echo "    (pass-1 apply would use enable_ilb_routing=false and destroy ILB routing). Set ORCHESTRATION_FORCE_PASS1=1 to force."
else
  echo "=== Step 2/6: Cluster + VPC — first apply (ILB off) ==="
  terraform apply -auto-approve "$@"
fi

PROJECT=$(terraform output -raw gcp_project_id)
ZONE=$(terraform output -raw availability_zone)
CLUSTER_NAME=$(terraform output -raw cluster_name)

echo "=== Step 3/6: Wait for machine-pool worker VMs ==="
wait_for_workers "$PROJECT" "$ZONE" "$CLUSTER_NAME"

echo "=== Step 4/6: Cluster — second apply (ILB + echo VM) ==="
cd "$CLUSTER_DIR"
terraform apply -auto-approve \
  -var='enable_ilb_routing=true' \
  -var='enable_echo_client_vm=true' \
  "$@"

echo "=== Step 5/6: oc login ==="
API_URL=$(terraform output -raw api_url)
ADMIN_USER=$(terraform output -raw admin_username)
ADMIN_PASS=$(terraform output -raw admin_password)
# shellcheck disable=SC2086
oc login "$API_URL" -u "$ADMIN_USER" -p "$ADMIN_PASS" $OC_LOGIN_EXTRA_ARGS

echo "=== Step 6/6: configure-routing.sh (canIpForward, FRR, CUDN, RouteAdvertisements) ==="
cd "$CLUSTER_DIR"
./scripts/configure-routing.sh \
  --project "$(terraform output -raw gcp_project_id)" \
  --region "$(terraform output -raw gcp_region)" \
  --cluster "$(terraform output -raw cluster_name)"

echo "=== ilb-apply complete ==="
echo "Optional: make ilb-e2e   # or: cd cluster_ilb_routing && ./scripts/deploy-cudn-test-pods.sh"
echo "          (README Quick start / oc get ra, etc.)."
