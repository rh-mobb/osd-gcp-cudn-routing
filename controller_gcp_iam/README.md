# `controller_gcp_iam` — BGP operator GCP IAM

Terraform root that provisions **GCP IAM** for the [BGP routing operator](../operator/README.md): custom role, service account, and **Workload Identity Federation** impersonation binding for the OpenShift **`ServiceAccount`**.

## Prerequisites

- **`wif_config/`** applied (WIF config exists in OCM).
- Same **`gcp_project_id`** and **`cluster_name`** as **`cluster_bgp_routing/`** (unless **`wif_config_display_name`** is set).
- **`osdgoogle` provider** credentials: **`OSDGOOGLE_TOKEN`** or **`TF_VAR_ocm_token`**, **`gcloud auth application-default login`** (same as other stacks).

## Apply

From the repository root:

```bash
make iam.init
make iam.apply
```

Or: `cd controller_gcp_iam && terraform init && terraform apply`

**Typical BGP lab:** use **`make bgp.deploy-operator`** after **`make bgp.run`** — it applies this stack, creates the WIF credential Secret, generates the `BGPRoutingConfig` from **`cluster_bgp_routing`** outputs, and deploys the operator in-cluster ([root README quick start](../README.md#quick-start--bgp)).

## Credential file and OpenShift Secret

After apply, generate **`credential-config.json`** and (optionally) create the Secret **without manual `gcloud` copy-paste**:

```bash
make iam.credentials
```

Options (environment):

| Variable | Default | Meaning |
|----------|---------|---------|
| `CONTROLLER_GCP_IAM_DIR` | _(repo)_`/controller_gcp_iam` | Terraform directory with applied state |
| `CONTROLLER_GCP_CRED_OUTPUT` | `./credential-config.json` | Output path for the JSON |
| `CONTROLLER_GCP_CRED_NAMESPACE` | `bgp-routing-system` | Namespace for **`oc apply`** Secret |
| `CONTROLLER_GCP_CRED_APPLY_SECRET` | unset | If **`1`**, create/update **`bgp-routing-gcp-credentials`** via `oc` |

Example with Secret:

```bash
CONTROLLER_GCP_CRED_APPLY_SECRET=1 make iam.credentials
```

Requires **`gcloud`** and (for **`--apply-secret`**) **`oc`** logged into the cluster.

## Troubleshooting: `invalid_grant` / audience mismatch

Describe the workload identity **OIDC** provider and read **`oidc.allowedAudiences`**. The projected ServiceAccount token’s **`aud`** claim must match **one of those strings exactly** (not the issuer URL unless it appears in the list; not the `//iam.googleapis.com/...` path unless that literal is listed). OpenShift Dedicated / OCM WIF often sets **`allowedAudiences: ["openshift"]`** while **`issuerUri`** is **`https://openshift.com`** — those differ; the default **`wif_kubernetes_token_audience`** is **`openshift`**.

```bash
cd controller_gcp_iam
terraform output -raw gcp_project_id
terraform output -raw workload_identity_provider_resource_name
gcloud iam workload-identity-pools providers describe PROVIDER_ID \
  --location=global --workload-identity-pool=POOL_ID --project=GCP_PROJECT_ID
```

Set **`wif_kubernetes_token_audience`** to the matching entry, then re-run **`make bgp.deploy-operator`** (or substitute **`terraform output -raw wif_kubernetes_token_audience`** into **`operator/deploy/deployment.yaml`** and **`oc apply`**). The **`credential-config.json`** `audience` field stays the **`//iam.googleapis.com/...`** form from **`create-cred-config`**; only the **Kubernetes** projected token **`aud`** must appear in **`allowedAudiences`**.

Optional: change **`allowedAudiences`** with **`gcloud iam workload-identity-pools providers update-oidc`** only if you control the provider and need extra values (the flag **replaces** the list). If **`update-oidc`** is denied, keep **`wif_kubernetes_token_audience`** aligned with OCM’s configuration.

## Troubleshooting: `iam.serviceAccounts.getAccessToken` denied (403)

After STS succeeds, **impersonation** needs **`roles/iam.workloadIdentityUser`** on the operator GCP service account for the correct **`principal://…/workloadIdentityPools/POOL/subject/system:serviceaccount:NAMESPACE:KSA`**. If the Terraform binding used the wrong principal form, apply the fixed module (**`make iam.apply`** or **`make bgp.deploy-operator`**) and confirm **`terraform output workload_identity_principal_member`** matches your **`ServiceAccount`** namespace and name. See **`gcloud iam service-accounts get-iam-policy`** on the operator SA.

## Destroy order

Destroy this stack **before** or **after** the cluster; if you remove the WIF config, apply/destroy here while OCM still exposes the WIF data source if you need to change IAM. Typical teardown after **`make bgp.deploy-operator`**: **`make destroy`** (**`bgp.destroy-operator`** + **`bgp.teardown`**) or **`make bgp.destroy-operator`** → **`make bgp.teardown`**. For IAM-only removal, use **`make iam.destroy`**.

## Module

Implementation: [`modules/osd-bgp-controller-iam/`](../modules/osd-bgp-controller-iam/README.md)
