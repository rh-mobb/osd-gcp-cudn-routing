#!/usr/bin/env bash
# Generate credential-config.json for the BGP controller (ADC file + WIF provider path from Terraform).
# Optionally create/update the OpenShift Secret referenced by deploy/deployment.yaml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${CONTROLLER_GCP_IAM_DIR:-$ROOT/controller_gcp_iam}"
OUT_FILE="${CONTROLLER_GCP_CRED_OUTPUT:-$PWD/credential-config.json}"
NAMESPACE="${CONTROLLER_GCP_CRED_NAMESPACE:-bgp-routing-system}"
SECRET_NAME="${CONTROLLER_GCP_CRED_SECRET_NAME:-bgp-routing-gcp-credentials}"
APPLY_SECRET=0

usage() {
  cat <<'EOF'
Usage: bgp-controller-gcp-credentials.sh [options]

  Reads terraform outputs from controller_gcp_iam (after apply) and runs
  gcloud iam workload-identity-pools create-cred-config.

Options:
  --tf-dir DIR       Terraform directory (default: repo/controller_gcp_iam or $CONTROLLER_GCP_IAM_DIR)
  -o, --output FILE  Write credential-config.json here (default: ./credential-config.json or $CONTROLLER_GCP_CRED_OUTPUT)
  -n, --namespace NS OpenShift namespace for --apply-secret (default: bgp-routing-system)
  --apply-secret     Create or update Secret bgp-routing-gcp-credentials via oc (needs oc login)

Environment:
  CONTROLLER_GCP_IAM_DIR, CONTROLLER_GCP_CRED_OUTPUT, CONTROLLER_GCP_CRED_NAMESPACE,
  CONTROLLER_GCP_CRED_SECRET_NAME, CONTROLLER_GCP_CRED_APPLY_SECRET=1
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage 0 ;;
    --tf-dir)
      TF_DIR="$2"
      shift 2
      ;;
    -o | --output)
      OUT_FILE="$2"
      shift 2
      ;;
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --apply-secret) APPLY_SECRET=1 ; shift ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for cmd in terraform gcloud; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: '$cmd' not found on PATH." >&2
    exit 1
  }
done

if [[ ! -d "$TF_DIR" ]]; then
  echo "Error: Terraform directory not found: $TF_DIR" >&2
  exit 1
fi

cd "$TF_DIR"
terraform init -input=false -upgrade

PROVIDER_RESOURCE="$(terraform output -raw workload_identity_provider_resource_name)"
SA_EMAIL="$(terraform output -raw gcp_service_account_email)"

TMP_ADCF="$(mktemp)"
cleanup() { rm -f "$TMP_ADCF"; }
trap cleanup EXIT

# create-cred-config requires application-default credentials (or explicit account).
gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  echo "Error: run 'gcloud auth application-default login' (or set valid ADC)." >&2
  exit 1
}

# Use the projected SA token (deployment volume) so aud matches the workload identity
# provider; the default in-cluster token uses https://kubernetes.default.svc / openshift.com,
# which Google's STS rejects (invalid_grant / audience mismatch).
gcloud iam workload-identity-pools create-cred-config \
  "$PROVIDER_RESOURCE" \
  --service-account="$SA_EMAIL" \
  --credential-source-file=/var/run/secrets/tokens/gcp-wif/token \
  --credential-source-type=text \
  --output-file="$TMP_ADCF"

mkdir -p "$(dirname "$OUT_FILE")"
cp -f "$TMP_ADCF" "$OUT_FILE"
echo "Wrote $OUT_FILE"

# Pool / provider IDs for gcloud (path: projects/NUM/locations/.../workloadIdentityPools/POOL/providers/PROVIDER_ID)
POOL_ID="${PROVIDER_RESOURCE#*workloadIdentityPools/}"
POOL_ID="${POOL_ID%%/providers/*}"
PROVIDER_ID="${PROVIDER_RESOURCE##*/providers/}"
GCP_PROJECT="$(terraform output -raw gcp_project_id 2>/dev/null || true)"
AUD_PARALLEL="//iam.googleapis.com/${PROVIDER_RESOURCE}"

echo ""
echo "Projected Kubernetes token 'aud' must match oidc.allowedAudiences (see describe below)."
echo "OCM/OSD often uses the literal \"openshift\" — set Terraform wif_kubernetes_token_audience, then"
echo "make bgp.deploy-controller (credential JSON audience stays ${AUD_PARALLEL})."
echo ""
echo "  gcloud iam workload-identity-pools providers describe ${PROVIDER_ID} \\"
echo "    --location=global --workload-identity-pool=${POOL_ID} --project=${GCP_PROJECT:-YOUR_GCP_PROJECT_ID}"
echo ""

if [[ "$APPLY_SECRET" -eq 1 ]] || [[ "${CONTROLLER_GCP_CRED_APPLY_SECRET:-}" == "1" ]]; then
  command -v oc >/dev/null 2>&1 || {
    echo "Error: 'oc' not found on PATH (required for --apply-secret)." >&2
    exit 1
  }
  oc create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-file=credential-config.json="$OUT_FILE" \
    --dry-run=client -o yaml | oc apply -f -
  echo "Applied Secret $SECRET_NAME in namespace $NAMESPACE"
fi
