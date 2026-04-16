#!/usr/bin/env bash
# After make bgp.run: apply controller_gcp_iam, WIF credential Secret, CRDs, operator RBAC,
# ImageStream + BuildConfig, Deployment (WIF volumes), binary build from operator/, then
# BGPRoutingConfig from cluster_bgp_routing terraform output.
#
# Optional BGP_OPERATOR_PREBUILT_IMAGE: skip ImageStream / BuildConfig / oc start-build and use
# that image directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${ROOT}/cluster_bgp_routing"
IAM_DIR="${ROOT}/controller_gcp_iam"
OPERATOR_DIR="${ROOT}/operator"
DEPLOY_DIR="${OPERATOR_DIR}/deploy"
NS="${BGP_CONTROLLER_NAMESPACE:-bgp-routing-system}"
PREBUILT_IMAGE="${BGP_OPERATOR_PREBUILT_IMAGE:-}"
INTERNAL_OPERATOR_IMAGE="image-registry.openshift-image-registry.svc:5000/${NS}/bgp-routing-operator:latest"

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

echo "=== Step 1/9: controller_gcp_iam (${IAM_DIR}) ==="
cd "$IAM_DIR"
terraform init -input=false -upgrade
terraform apply -auto-approve "$@"

echo "=== Step 2/9: Namespace ${NS} ==="
oc apply -f "${DEPLOY_DIR}/namespace.yaml"

echo "=== Step 3/9: WIF credential Secret (${NS}) ==="
CONTROLLER_GCP_IAM_DIR="$IAM_DIR" \
  CONTROLLER_GCP_CRED_NAMESPACE="$NS" \
  CONTROLLER_GCP_CRED_APPLY_SECRET=1 \
  bash "${ROOT}/scripts/bgp-controller-gcp-credentials.sh"

echo "=== Step 4/9: CRDs (routing.osd.redhat.com) ==="
oc apply -f "${OPERATOR_DIR}/config/crd/bases/"

echo "=== Step 5/9: Operator RBAC (${NS}) ==="
oc apply -f "${DEPLOY_DIR}/rbac.yaml"

echo "=== Step 6/9: Terraform outputs → BGPRoutingConfig cluster ==="
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

case "$SITE_TO_SITE" in
  true | True | 1) SITE_BOOL="true" ;;
  *) SITE_BOOL="false" ;;
esac

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
apiVersion: routing.osd.redhat.com/v1alpha1
kind: BGPRoutingConfig
metadata:
  name: cluster
spec:
  suspended: false
  gcpProject: "${GCP_Q}"
  clusterName: "${CLUSTER_Q}"
  cloudRouter:
    name: "${ROUTER_Q}"
    region: "${REGION_Q}"
  ncc:
    hubName: "${HUB_Q}"
    spokePrefix: "${SPOKE_PREFIX_Q}"
    siteToSite: ${SITE_BOOL}
  frr:
    asn: ${FRR_ASN}
  gce:
    enableNestedVirtualization: true
  nodeSelector:
    labelKey: "node-role.kubernetes.io/worker"
    labelValue: ""
    routerLabelKey: "routing.osd.redhat.com/bgp-router"
    infraExcludeLabelKey: "node-role.kubernetes.io/infra"
  reconcileIntervalSeconds: 60
  debounceSeconds: 5
EOF

if [[ -n "${PREBUILT_IMAGE}" ]]; then
  OPERATOR_IMAGE="${PREBUILT_IMAGE}"
  echo "=== Step 7/9: Deployment (${NS}) — prebuilt image (skip ImageStream / BuildConfig) ==="
else
  OPERATOR_IMAGE="${INTERNAL_OPERATOR_IMAGE}"
  echo "=== Step 7/9: ImageStream, BuildConfig (${NS}) ==="
  oc apply -f "${DEPLOY_DIR}/imagestream.yaml"
  oc apply -f "${DEPLOY_DIR}/buildconfig.yaml"
fi

WIF_AUDIENCE="$(cd "$IAM_DIR" && terraform output -raw wif_kubernetes_token_audience)"
sed -e "s|__BGP_OPERATOR_WIF_AUDIENCE__|${WIF_AUDIENCE}|g" \
  -e "s|__BGP_OPERATOR_IMAGE__|${OPERATOR_IMAGE}|g" "${DEPLOY_DIR}/deployment.yaml" | oc apply -f -

if [[ -z "${PREBUILT_IMAGE}" ]]; then
  echo "=== Step 8/9: Binary build (${OPERATOR_DIR}) ==="
  cd "$OPERATOR_DIR"
  oc start-build bgp-routing-operator -n "$NS" --from-dir="${PWD}" --follow
else
  echo "=== Step 8/9: Skipping oc start-build (using ${PREBUILT_IMAGE}) ==="
fi

echo "=== Step 9/9: Rollout deployment/bgp-routing-operator (${NS}) ==="
oc rollout restart "deployment/bgp-routing-operator" -n "$NS"
oc rollout status "deployment/bgp-routing-operator" -n "$NS" --timeout=600s

echo "=== bgp-deploy-operator-incluster complete ==="
echo "Optional: watch 'oc get nodes -l routing.osd.redhat.com/bgp-router='"
echo "Optional: make bgp.e2e"
