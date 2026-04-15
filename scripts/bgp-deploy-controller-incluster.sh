#!/usr/bin/env bash
# After make bgp.run: apply controller_gcp_iam, WIF credential Secret, ConfigMap from
# cluster_bgp_routing terraform output, and OpenShift rollout (no hand-edited YAML).
# Optional BGP_CONTROLLER_PREBUILT_IMAGE: skip ImageStream / BuildConfig / oc start-build and
# deploy that image (used by make create).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"
IAM_DIR="${ROOT}/controller_gcp_iam"
DEPLOY_DIR="${ROOT}/controller/go/deploy"
NS="${BGP_CONTROLLER_NAMESPACE:-bgp-routing-system}"
# When set (e.g. make create), skip ImageStream / BuildConfig / oc start-build and deploy this image instead.
PREBUILT_IMAGE="${BGP_CONTROLLER_PREBUILT_IMAGE:-}"
INTERNAL_CONTROLLER_IMAGE="image-registry.openshift-image-registry.svc:5000/bgp-routing-system/bgp-routing-controller:latest"

for cmd in terraform oc gcloud; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: required command '$cmd' not found on PATH." >&2
    exit 1
  }
done

gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  echo "Error: run 'gcloud auth application-default login'." >&2
  exit 1
}

oc whoami >/dev/null 2>&1 || {
  echo "Error: not logged in — run 'make bgp.run' first (or oc login)." >&2
  exit 1
}

echo "=== Step 1/6: controller_gcp_iam (${IAM_DIR}) ==="
cd "$IAM_DIR"
terraform init -input=false -upgrade
terraform apply -auto-approve "$@"

echo "=== Step 2/6: Namespace ${NS} (required before Secret / ConfigMap) ==="
oc apply -f "${DEPLOY_DIR}/namespace.yaml"

echo "=== Step 3/6: WIF credential Secret (${NS}) ==="
CONTROLLER_GCP_IAM_DIR="$IAM_DIR" \
  CONTROLLER_GCP_CRED_NAMESPACE="$NS" \
  CONTROLLER_GCP_CRED_APPLY_SECRET=1 \
  bash "${ROOT}/scripts/bgp-controller-gcp-credentials.sh"

echo "=== Step 4/6: ConfigMap from ${CLUSTER_DIR} terraform output ==="
cd "$CLUSTER_DIR"
GCP_PROJECT=$(terraform output -raw gcp_project_id)
CLUSTER_NAME=$(terraform output -raw cluster_name)
CLOUD_ROUTER_NAME=$(terraform output -raw cloud_router_name)
CLOUD_ROUTER_REGION=$(terraform output -raw gcp_region)
NCC_HUB_NAME=$(terraform output -raw ncc_hub_name)
NCC_SPOKE_PREFIX=$(terraform output -raw ncc_spoke_prefix)
FRR_ASN=$(terraform output -raw frr_asn)
SITE_TO_SITE=$(terraform output -raw ncc_spoke_site_to_site_data_transfer)

test -n "${CLOUD_ROUTER_NAME}" && test -n "${NCC_HUB_NAME}" && test -n "${NCC_SPOKE_PREFIX}" || {
  echo "Error: BGP outputs empty — ensure enable_bgp_routing=true was applied in ${CLUSTER_DIR}." >&2
  exit 1
}

# Lowercase bool for controller env parsing
case "$SITE_TO_SITE" in
  true | True | 1) SITE_STR="true" ;;
  *) SITE_STR="false" ;;
esac

# YAML string values (escape double quotes for data values)
yaml_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

GCP_Q=$(yaml_quote "$GCP_PROJECT")
CLUSTER_Q=$(yaml_quote "$CLUSTER_NAME")
ROUTER_Q=$(yaml_quote "$CLOUD_ROUTER_NAME")
REGION_Q=$(yaml_quote "$CLOUD_ROUTER_REGION")
HUB_Q=$(yaml_quote "$NCC_HUB_NAME")
SPOKE_PREFIX_Q=$(yaml_quote "$NCC_SPOKE_PREFIX")

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bgp-routing-controller
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: bgp-routing-controller
data:
  GCP_PROJECT: "${GCP_Q}"
  CLUSTER_NAME: "${CLUSTER_Q}"
  CLOUD_ROUTER_NAME: "${ROUTER_Q}"
  CLOUD_ROUTER_REGION: "${REGION_Q}"
  NCC_HUB_NAME: "${HUB_Q}"
  NCC_SPOKE_PREFIX: "${SPOKE_PREFIX_Q}"
  FRR_ASN: "${FRR_ASN}"
  NCC_SPOKE_SITE_TO_SITE: "${SITE_STR}"
  ENABLE_GCE_NESTED_VIRTUALIZATION: "true"
  NODE_LABEL_KEY: "node-role.kubernetes.io/worker"
  NODE_LABEL_VALUE: ""
  ROUTER_LABEL_KEY: "cudn.redhat.com/bgp-router"
  INFRA_EXCLUDE_LABEL_KEY: "node-role.kubernetes.io/infra"
  RECONCILE_INTERVAL_SECONDS: "60"
  DEBOUNCE_SECONDS: "5"
EOF

if [[ -n "${PREBUILT_IMAGE}" ]]; then
  CONTROLLER_IMAGE="${PREBUILT_IMAGE}"
  echo "=== Step 5/6: RBAC, Deployment (${NS}) — prebuilt image (skip ImageStream / BuildConfig) ==="
  oc apply -f "${DEPLOY_DIR}/rbac.yaml"
else
  CONTROLLER_IMAGE="${INTERNAL_CONTROLLER_IMAGE}"
  echo "=== Step 5/6: RBAC, ImageStream, BuildConfig, Deployment ==="
  oc apply -f "${DEPLOY_DIR}/rbac.yaml"
  oc apply -f "${DEPLOY_DIR}/imagestream.yaml"
  oc apply -f "${DEPLOY_DIR}/buildconfig.yaml"
fi
# Projected token aud must match an OIDC allowedAudiences entry (see gcloud … providers describe).
# OSD/OCM WIF typically uses the literal "openshift", not //iam.googleapis.com/...
WIF_AUDIENCE="$(cd "$IAM_DIR" && terraform output -raw wif_kubernetes_token_audience)"
sed -e "s|__BGP_CONTROLLER_WIF_AUDIENCE__|${WIF_AUDIENCE}|g" \
  -e "s|__BGP_CONTROLLER_IMAGE__|${CONTROLLER_IMAGE}|g" "${DEPLOY_DIR}/deployment.yaml" | oc apply -f -

if [[ -z "${PREBUILT_IMAGE}" ]]; then
  echo "=== Step 6/6: Binary build + restart Deployment (${NS}) ==="
  cd "${ROOT}/controller/go"
  # Use --from-dir "${PWD}" not --from-dir=. : on bash, =. can tokenize as sourcing "." with arg "--follow".
  oc start-build bgp-routing-controller -n "$NS" --from-dir="${PWD}" --follow
else
  echo "=== Step 6/6: Rollout (${NS}) — prebuilt image ==="
  echo ">>> Skipping oc start-build (using ${PREBUILT_IMAGE})"
fi
# Pushing to the same ImageStreamTag (:latest) does not change the Deployment spec; restart so pods run the new image.
oc rollout restart "deployment/bgp-routing-controller" -n "$NS"
oc rollout status "deployment/bgp-routing-controller" -n "$NS" --timeout=600s

echo "=== bgp-deploy-controller-incluster complete ==="
echo "Optional: make bgp.e2e   (wait for BGP Established if the check is flaky)"
