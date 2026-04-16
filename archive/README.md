# Archived reference stacks and legacy controllers

This directory holds **archived** components that are no longer actively maintained. The active development path is the [**operator**](../operator/README.md) under `operator/`.

## Layout

| Path | Contents |
|------|----------|
| `cluster_ilb_routing/` | ILB reference deployment (Terraform root) |
| `modules/osd-ilb-routing/` | Reusable ILB Terraform module |
| `controller/go/` | Legacy Go / controller-runtime BGP routing controller (replaced by [`operator/`](../operator/README.md)) |
| `controller/python/` | Legacy Python / kopf BGP routing controller prototype |
| `scripts/ilb-apply.sh`, `scripts/ilb-destroy.sh` | End-to-end ILB apply / destroy (WIF at repo root) |
| `scripts/bgp-deploy-controller-incluster.sh` | Legacy in-cluster controller deploy script (replaced by [`scripts/bgp-deploy-operator-incluster.sh`](../scripts/bgp-deploy-operator-incluster.sh)) |
| `scripts/terraform-controller-env-from-json.sh` | Terraform output → env vars for legacy controller local runs |
| `ILB-vs-BGP.md` | Side-by-side comparison with the BGP approach |

**Workload Identity Federation (WIF)** still lives at the repository root in `wif_config/`. Archived scripts expect that layout.

## Using the ILB archive

From the repository root:

```bash
bash archive/scripts/ilb-apply.sh
bash archive/scripts/ilb-destroy.sh
```

Use a separate Terraform state and `terraform.tfvars` from the active BGP stack (`cluster_bgp_routing/`).

## Legacy controllers

The **Go** and **Python** BGP controllers under `controller/` have been replaced by the [**operator**](../operator/README.md) (`routing.osd.redhat.com/v1alpha1` CRDs). They remain here for historical reference. The operator implements the same reconciliation logic (NCC spokes, Cloud Router peers, `canIpForward`, FRR CRs) with a declarative CRD configuration surface instead of ConfigMap/env-var configuration.

To run the archived controllers, see their READMEs:

- [`controller/go/README.md`](controller/go/README.md)
- [`controller/python/README.md`](controller/python/README.md)
