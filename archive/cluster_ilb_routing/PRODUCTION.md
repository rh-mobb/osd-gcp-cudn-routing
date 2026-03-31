# Production readiness — ILB reference stack

> **Archived.** The **ILB** path is not maintained as the active reference; use [**cluster_bgp_routing/**](../cluster_bgp_routing/README.md) and the repo [**PRODUCTION.md**](../PRODUCTION.md) for current production-readiness context.

Supplements the repo-wide [PRODUCTION.md](../PRODUCTION.md) (shared gaps, operations). Read that first for **cross-cutting** automation and security expectations.

For PoC limits in this stack, see [Known limitations](README.md#known-limitations-ilb-focused) in [README.md](README.md).

---

## ILB-specific gaps

1. **ILB backends stay in sync with live workers.** Reference Terraform discovers workers with **`discover-workers.sh`** on **apply**; **unmanaged instance groups** do not update themselves when OCM adds or swaps machines. Production needs **periodic or event-driven** updates (controller, CI pipeline, or Terraform on a schedule).

2. **Health checks.** The PoC uses **TCP 10250 (kubelet)** for ILB probes. That proves node reachability, not that **OVN / FRR / routing** is healthy. Production should define a **routing-ready** signal (for example a dedicated probe or readiness gate) before sending production traffic.

3. **GCP routability per distinct CUDN (or routed) CIDR.** Anything the **VPC must reach** via the ILB path needs a **static route** (and **firewall** semantics) for that prefix. **Multiple routes** often share the **same internal passthrough ILB** as next hop; [**`modules/osd-ilb-routing`**](../modules/osd-ilb-routing/README.md) currently takes **one `cudn_cidr`**, so **several overlays** require **extending IaC** (multiple routes, combined `destination_ranges`, or multiple module instances).

4. **Multi-zone instance groups and capacity.** The reference stack may be **single-AZ** or minimal. Production needs explicit **per-zone unmanaged instance groups**, quotas, and failure-domain assumptions aligned with worker distribution.

5. **`configure-routing.sh` and Terraform** — flags such as **`--cudn-cidr`**, **`--cudn-name`**, **`--namespace`** must match **`google_compute_route`** destinations and CRs. Prefer **GitOps** or **controller-managed** alignment in production (see shared [PRODUCTION.md](../PRODUCTION.md)).
