# Archived ILB reference stack

This directory holds the **internal load balancer (ILB)** Terraform module, reference root module, comparison doc, and orchestration scripts. The active development path in this repository is **BGP + Network Connectivity Center** only; ILB is kept for historical reference and one-off use.

## Layout

| Path | Contents |
|------|----------|
| `cluster_ilb_routing/` | ILB reference deployment (Terraform root) |
| `modules/osd-ilb-routing/` | Reusable ILB Terraform module |
| `scripts/ilb-apply.sh`, `scripts/ilb-destroy.sh` | End-to-end apply / destroy (WIF at repo root) |
| `ILB-vs-BGP.md` | Side-by-side comparison with the BGP approach |

**Workload Identity Federation (WIF)** still lives at the repository root in `wif_config/`. Archived scripts expect that layout.

## Using the archive

From the repository root:

```bash
bash archive/scripts/ilb-apply.sh
bash archive/scripts/ilb-destroy.sh
```

Use a separate Terraform state and `terraform.tfvars` from the active BGP stack (`cluster_bgp_routing/`).
