# `controller_gcp_iam` — BGP controller GCP IAM

Terraform root that provisions **GCP IAM** for the [BGP routing controller](../controller/python/README.md): custom role, service account, and **Workload Identity Federation** impersonation binding for the OpenShift **`ServiceAccount`**.

## Prerequisites

- **`wif_config/`** applied (WIF config exists in OCM).
- Same **`gcp_project_id`** and **`cluster_name`** as **`cluster_bgp_routing/`** (unless **`wif_config_display_name`** is set).
- **`osdgoogle` provider** credentials: **`OSDGOOGLE_TOKEN`** or **`TF_VAR_ocm_token`**, **`gcloud auth application-default login`** (same as other stacks).

## Apply

From the repository root:

```bash
make controller.gcp-iam.init
make controller.gcp-iam.apply
```

Or: `cd controller_gcp_iam && terraform init && terraform apply`

**Typical BGP lab:** use **`make bgp.deploy-controller`** after **`make bgp.run`** — it applies this stack, creates the WIF credential Secret, generates the controller ConfigMap from **`cluster_bgp_routing`** outputs, and deploys the operator in-cluster ([root README quick start](../README.md#quick-start--bgp)).

## Credential file and OpenShift Secret

After apply, generate **`credential-config.json`** and (optionally) create the Secret **without manual `gcloud` copy-paste**:

```bash
make controller.gcp-credentials
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
CONTROLLER_GCP_CRED_APPLY_SECRET=1 make controller.gcp-credentials
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

Set **`wif_kubernetes_token_audience`** to the matching entry, then re-run **`make bgp.deploy-controller`** (or substitute **`terraform output -raw wif_kubernetes_token_audience`** into **`deploy/deployment.yaml`** and **`oc apply`**). The **`credential-config.json`** `audience` field stays the **`//iam.googleapis.com/...`** form from **`create-cred-config`**; only the **Kubernetes** projected token **`aud`** must appear in **`allowedAudiences`**.

Optional: change **`allowedAudiences`** with **`gcloud iam workload-identity-pools providers update-oidc`** only if you control the provider and need extra values (the flag **replaces** the list). If **`update-oidc`** is denied, keep **`wif_kubernetes_token_audience`** aligned with OCM’s configuration.

## Troubleshooting: `iam.serviceAccounts.getAccessToken` denied (403)

After STS succeeds, **impersonation** needs **`roles/iam.workloadIdentityUser`** on the controller GCP service account for the correct **`principal://…/workloadIdentityPools/POOL/subject/system:serviceaccount:NAMESPACE:KSA`**. If the Terraform binding used the wrong principal form, apply the fixed module (**`make controller.gcp-iam.apply`** or **`make bgp.deploy-controller`**) and confirm **`terraform output workload_identity_principal_member`** matches your **`ServiceAccount`** namespace and name. See **`gcloud iam service-accounts get-iam-policy`** on the controller SA.

## Destroy order

Destroy this stack **before** or **after** the cluster; if you remove the WIF config, apply/destroy here while OCM still exposes the WIF data source if you need to change IAM. Typical teardown: **`make controller.cleanup`** → **`make bgp.teardown`**; run **`make controller.gcp-iam.destroy`** around the same window (before **`wif.destroy`**) if you want the SA removed.

## Module

Implementation: [`modules/osd-bgp-controller-iam/`](../modules/osd-bgp-controller-iam/README.md)
