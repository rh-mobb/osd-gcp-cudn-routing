# BGP stack: manual provision and teardown

This document is the **full manual workflow** behind the repository’s scripted path: **Workload Identity Federation**, **cluster + static BGP Terraform**, **one-time cluster routing configuration**, **operator IAM and in-cluster install**, then (when you are finished) **ordered teardown** of operator state, **IAM**, **cluster**, and **WIF**.

It intentionally uses **no Makefile targets** — only **`terraform`**, **`oc`**, **`gcloud`**, **`bash`**, and paths under this repository.

For prerequisites, tokens, and variable naming, start from the [root README](../README.md#shared-prerequisites) and [scripts/README.md](../scripts/README.md).

## Conventions

- **`REPO`**: root directory of your clone of this repository (the directory that contains **`wif_config/`**, **`cluster_bgp_routing/`**, **`scripts/`**, **`operator/`**, **`controller_gcp_iam/`**).
- **Operator namespace**: **`bgp-routing-system`**, unless you set **`BGP_CONTROLLER_NAMESPACE`** when following the deploy steps (the scripts default to **`bgp-routing-system`**).
- **Extra Terraform arguments**: If you use **`-var-file=…`**, **`-var=…`**, or other flags for backends and variables, **append the same arguments** to every **`terraform apply`** and **`terraform destroy`** in this document that applies to that stack (**`wif_config`**, **`cluster_bgp_routing`**, **`controller_gcp_iam`**), so plan/apply/destroy stay consistent.

---

## Part 1 — Provision (full stack)

### 1. WIF (`wif_config/`)

```bash
cd "${REPO}/wif_config"
terraform init -upgrade
terraform apply -auto-approve
```

Creates **Workload Identity Federation** configuration aligned with OCM / OSD-GCP. **`cluster_name`** and **`gcp_project_id`** must match what you use for the cluster stack.

### 2. Cluster, VPC, and static BGP (`cluster_bgp_routing/`)

```bash
cd "${REPO}/cluster_bgp_routing"
terraform init -upgrade
terraform apply -auto-approve \
  -var='enable_bgp_routing=true' \
  -var='enable_echo_client_vm=true'
```

Creates the **OSD cluster**, **VPC**, **NCC hub**, **Cloud Router** (static side), **echo VM**, firewalls, and related resources. **NCC spokes**, **Cloud Router BGP peers**, **`canIpForward`**, and **`FRRConfiguration`** CRs are reconciled later by the **operator**, not finalized here.

### 3. Log in to the API (`oc login`)

From **`cluster_bgp_routing/`** (so **`terraform output`** resolves):

```bash
cd "${REPO}/cluster_bgp_routing"
API_URL=$(terraform output -raw api_url)
ADMIN_USER=$(terraform output -raw admin_username)
ADMIN_PASS=$(terraform output -raw admin_password)
```

**TLS:** Until the API presents a publicly trusted certificate, non-interactive login often needs **`--insecure-skip-tls-verify`**. The automation in **`scripts/bgp-apply.sh`** defaults **`OC_LOGIN_EXTRA_ARGS`** to that value and can wait for public TLS when you omit the insecure flag; see **`scripts/orchestration-lib.sh`** for the wait helper.

Typical login (matches the common automated path):

```bash
oc login "$API_URL" -u "$ADMIN_USER" -p "$ADMIN_PASS" --insecure-skip-tls-verify
```

If that fails, retry with the same flags (the apply script retries with **`--insecure-skip-tls-verify`** explicitly).

### 4. One-time routing on the cluster (`configure-routing.sh`)

Still from **`cluster_bgp_routing/`**:

```bash
cd "${REPO}/cluster_bgp_routing"
./scripts/configure-routing.sh \
  --project "$(terraform output -raw gcp_project_id)" \
  --region "$(terraform output -raw gcp_region)" \
  --cluster "$(terraform output -raw cluster_name)"
```

Enables **FRR** and **RouteAdvertisements**, waits for **`openshift-frr-k8s`**, creates the **CUDN** namespace and **`ClusterUserDefinedNetwork`**, and applies **RouteAdvertisements**. See [references/fix-bgp-ra.md](../references/fix-bgp-ra.md) for **RouteAdvertisements** constraints. This step does **not** install the BGP operator.

### 5. Operator GCP IAM (`controller_gcp_iam/`)

Requires **`gcloud auth application-default login`** (the next step uses ADC). You must still be logged in with **`oc`**.

```bash
cd "${REPO}/controller_gcp_iam"
terraform init -input=false -upgrade
terraform apply -auto-approve
```

Creates the **GCP service account**, **custom role**, and **WIF** binding used by the operator to call GCP APIs.

### 6. Operator namespace

```bash
export NS="${BGP_CONTROLLER_NAMESPACE:-bgp-routing-system}"
oc apply -f "${REPO}/operator/deploy/namespace.yaml"
```

### 7. WIF credential Secret in the operator namespace

```bash
CONTROLLER_GCP_IAM_DIR="${REPO}/controller_gcp_iam" \
  CONTROLLER_GCP_CRED_NAMESPACE="${NS}" \
  CONTROLLER_GCP_CRED_APPLY_SECRET=1 \
  bash "${REPO}/scripts/bgp-controller-gcp-credentials.sh"
```

### 8. CRDs and RBAC

```bash
oc apply -f "${REPO}/operator/config/crd/bases/"
oc apply -f "${REPO}/operator/deploy/rbac.yaml"
```

### 9. `BGPRoutingConfig` from Terraform outputs

The operator expects a cluster-scoped **`BGPRoutingConfig`** named **`cluster`**. Values come from **`cluster_bgp_routing`** outputs (same pattern as **`scripts/bgp-deploy-operator-incluster.sh`**):

```bash
cd "${REPO}/cluster_bgp_routing"
GCP_PROJECT=$(terraform output -raw gcp_project_id)
CLUSTER_NAME=$(terraform output -raw cluster_name)
CLOUD_ROUTER_NAME=$(terraform output -raw cloud_router_name)
CLOUD_ROUTER_REGION=$(terraform output -raw gcp_region)
NCC_HUB_NAME=$(terraform output -raw ncc_hub_name)
NCC_SPOKE_PREFIX=$(terraform output -raw ncc_spoke_prefix)
FRR_ASN=$(terraform output -raw frr_asn)
SITE_TO_SITE=$(terraform output -raw ncc_spoke_site_to_site_data_transfer)

case "${SITE_TO_SITE}" in
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
```

### 10. Operator image: prebuilt (registry) or in-cluster build

**Option A — Pull a prebuilt image (typical CI image)**

Set the image reference (example matches the image this repository publishes to GHCR):

```bash
OPERATOR_IMAGE="ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-routing-operator:latest"
```

Private registries need an **image pull Secret** on the operator namespace and a **`imagePullSecrets`** reference on the Deployment (not covered here).

**Option B — Build from local `operator/` source inside the cluster**

```bash
oc apply -f "${REPO}/operator/deploy/imagestream.yaml"
oc apply -f "${REPO}/operator/deploy/buildconfig.yaml"
OPERATOR_IMAGE="image-registry.openshift-image-registry.svc:5000/${NS}/bgp-routing-operator:latest"
```

### 11. Deployment (substitute WIF audience and image)

```bash
WIF_AUDIENCE="$(cd "${REPO}/controller_gcp_iam" && terraform output -raw wif_kubernetes_token_audience)"
sed -e "s|__BGP_OPERATOR_WIF_AUDIENCE__|${WIF_AUDIENCE}|g" \
  -e "s|__BGP_OPERATOR_IMAGE__|${OPERATOR_IMAGE}|g" \
  "${REPO}/operator/deploy/deployment.yaml" | oc apply -f -
```

### 12. In-cluster build (Option B only)

If you chose **Option B** in step 10:

```bash
cd "${REPO}/operator"
oc start-build bgp-routing-operator -n "${NS}" --from-dir="${PWD}" --follow
```

Skip this if you used **Option A**.

### 13. Roll out the operator Deployment

```bash
oc rollout restart "deployment/bgp-routing-operator" -n "${NS}"
oc rollout status "deployment/bgp-routing-operator" -n "${NS}" --timeout=600s
```

The operator then reconciles **NCC spokes**, **BGP peers**, **node networking features**, **`FRRConfiguration` CRs**, and **`routing.osd.redhat.com/bgp-router`** labels. Allow time before expecting stable routes.

### 14. Optional checks after provision

Watch router-labeled nodes until each shows **Ready** for your expected worker count:

```bash
watch 'oc get nodes -l routing.osd.redhat.com/bgp-router='
```

End-to-end **CUDN pod ↔ echo VM** checks (requires **`oc`**, **`jq`**, **`gcloud`**, **`terraform`** on **`PATH`**):

```bash
bash "${REPO}/scripts/e2e-cudn-connectivity.sh" -C "${REPO}/cluster_bgp_routing"
```

---

## Part 2 — Teardown (full stack)

**Order matters.** If the operator still owns **Cloud Router** peers or **NCC** spoke attachments, destroying **`cluster_bgp_routing`** first can **block or fail**. Complete **Part 2** in sequence.

### 1. Delete `BGPRoutingConfig` (finalizer cleanup)

```bash
oc delete bgproutingconfig cluster --ignore-not-found=true --timeout=120s
```

### 2. Delete operator workload and RBAC

These commands match the repository teardown behavior (best-effort if resources are already gone):

```bash
oc delete -f "${REPO}/operator/deploy/deployment.yaml" --ignore-not-found=true
oc delete -f "${REPO}/operator/deploy/rbac.yaml" --ignore-not-found=true
```

The Makefile does **not** delete **`namespace.yaml`** here; the namespace may remain until you remove it explicitly if you want it gone.

### 3. Delete CRDs

```bash
oc delete -f "${REPO}/operator/config/crd/bases/" --ignore-not-found=true
```

### 4. Destroy operator IAM (`controller_gcp_iam/`)

```bash
cd "${REPO}/controller_gcp_iam"
terraform init -upgrade
terraform destroy -auto-approve
```

### 5. Destroy cluster stack (`cluster_bgp_routing/`)

```bash
cd "${REPO}/cluster_bgp_routing"
terraform init -upgrade
terraform destroy -auto-approve
```

### 6. Destroy WIF (`wif_config/`)

```bash
cd "${REPO}/wif_config"
terraform init -upgrade
terraform destroy -auto-approve
```

**Note:** Anything you created by hand on OpenShift or in GCP outside Terraform is **not** removed by the steps above.

---

## Scripted shortcuts (optional)

If you prefer not to type each step, the same ordering is implemented as:

- **`scripts/bgp-apply.sh`** — Part 1, §§1–4  
- **`scripts/bgp-deploy-operator-incluster.sh`** — Part 1, §§5–13 (set **`BGP_OPERATOR_PREBUILT_IMAGE`** for Option A; omit it for Option B)  
- **`scripts/bgp-destroy.sh`** — Part 2, §§5–6 only (run **after** operator and **`controller_gcp_iam`** teardown)

---

## See also

- [README.md — Quick start](../README.md#quick-start--bgp)  
- [cluster_bgp_routing/README.md](../cluster_bgp_routing/README.md)  
- [controller_gcp_iam/README.md](../controller_gcp_iam/README.md)  
- [operator/README.md](../operator/README.md)  
