# `osd-bgp-controller-iam`

Terraform module: **GCP least-privilege IAM** for the [BGP routing controller](../../controller/python/README.md).

Creates:

- Custom IAM role (NCC spokes + **`networkconnectivity.operations.get`** for LRO polling, Cloud Router read/update, GCE instances update/list, zones list)
- Dedicated GCP service account
- Project-level binding of the custom role to that SA
- **`roles/iam.workloadIdentityUser`** on the GCP SA for **`principal://iam.googleapis.com/projects/…/workloadIdentityPools/POOL/subject/system:serviceaccount:NAMESPACE:KSA`** (see [Google: Kubernetes WIF impersonation](https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes#service-account-impersonation))

## Usage

This module is invoked from the root stack [`controller_gcp_iam/`](../../controller_gcp_iam/README.md), which resolves **`data.osdgoogle_wif_config`** and passes pool or provider IDs plus the project number used in WIF resource paths.

## Inputs

See [`variables.tf`](variables.tf). Defaults match [`deploy/rbac.yaml`](../../controller/python/deploy/rbac.yaml) (`bgp-routing-system` / `bgp-routing-controller`).

## Outputs

- `gcp_service_account_email`, `workload_identity_provider_resource_name` — consumed by [`scripts/bgp-controller-gcp-credentials.sh`](../../scripts/bgp-controller-gcp-credentials.sh) to generate **`credential-config.json`**.
