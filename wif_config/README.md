# WIF Config

Creates a Workload Identity Federation (WIF) config in OCM using the [`osd-wif-config`](https://github.com/rh-mobb/terraform-provider-osd-google/tree/main/modules/osd-wif-config) module from [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google) (Git source). This config is shared infrastructure for `cluster_ilb_routing/`. It must be applied **in a separate Terraform run** before the cluster — see [Why a separate apply?](#why-a-separate-apply) below.

From this repository root you can use `make wif.apply` / `make wif.destroy`, or run Terraform directly under `wif_config/`.

## Why a separate apply?

The cluster stack uses `data.osdgoogle_wif_config` to look up the WIF config by display name. That data source only resolves when the WIF config **already exists** in OCM.

In addition, OCM returns a blueprint (workload identity pool ID, service accounts, custom roles, IAM bindings) as computed attributes **after** the WIF config is created. The GCP sub-module uses `for_each` over that blueprint. Terraform requires `for_each` keys to be known at plan time, but the blueprint is only available after the resource exists. Splitting into two configs avoids this: `wif_config/` creates the WIF config; `cluster_ilb_routing/` then looks it up via the data source and provisions GCP + the cluster.

## Variables

- **`gcp_project_id`** (required) — GCP project ID.
- **`cluster_name`** (default: `my-cluster`) — Base name. WIF display name is `cluster_name-wif`.
- **`openshift_version`** (default: `4.21.3`) — OpenShift version. WIF roles use x.y only.
- **`role_prefix`** (optional) — Prefix for custom IAM roles. Defaults to `cluster_name` with hyphens/underscores stripped.

## Standalone usage

```bash
cd wif_config
terraform init -upgrade
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: gcp_project_id, cluster_name, ...
terraform apply
```

Or from the repository root:

```bash
make wif.init
make wif.apply
```

Variables can also be set with `TF_VAR_gcp_project_id`, `TF_VAR_cluster_name`, etc.

## Keep in sync with `cluster_ilb_routing`

Use the **same** **`gcp_project_id`** and **`cluster_name`** in `wif_config/terraform.tfvars` (or equivalent `TF_VAR_*`) as in **`cluster_ilb_routing/terraform.tfvars`**. Align **`openshift_version`** with the cluster stack: WIF roles use the **x.y** stream, so the **minor** version should match what you deploy (see variables in both directories).
