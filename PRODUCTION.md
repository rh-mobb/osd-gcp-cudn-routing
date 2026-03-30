# Production readiness (overview)

This repository is a **proof of concept**. Nothing here is presented as production-ready. This document is the **shared** view: controller direction, **cross-cutting** gaps, security, and operations. **Path-specific** checklists live next to each reference stack:

| Stack | Checklist |
|-------|-----------|
| **ILB** (`cluster_ilb_routing/`) | [**cluster_ilb_routing/PRODUCTION.md**](cluster_ilb_routing/PRODUCTION.md) — backends, kubelet health probes, static routes / multiple CUDNs, per-zone instance groups |
| **BGP** (`cluster_bgp_routing/`) | [**cluster_bgp_routing/PRODUCTION.md**](cluster_bgp_routing/PRODUCTION.md) — NCC/Cloud Router sync, per-node FRR, router IPs, IAM, ASN/monitoring; **actionable roadmap:** [**PRODUCTION-ROADMAP.md**](cluster_bgp_routing/PRODUCTION-ROADMAP.md) |

For PoC limits already stated in-repo, see [Known limitations (ILB)](cluster_ilb_routing/README.md#known-limitations-ilb-focused) and [Known limitations (BGP)](cluster_bgp_routing/README.md#known-limitations). For choosing between approaches, see [ILB-vs-BGP.md](ILB-vs-BGP.md).

## Terraform state

Use **remote state** (for example **GCS** with versioning and locking) for anything beyond a single-developer lab. See [docs/terraform-backend-gcs.md](docs/terraform-backend-gcs.md) and each stack’s **`backend.tf.example`** under **`cluster_ilb_routing/`** and **`cluster_bgp_routing/`**.

---

## Kubernetes controller (recommended direction)

Many production items require **reacting to cluster and infrastructure events** on an ongoing basis. A **Kubernetes controller** (Operator pattern, or a small controller with **WIF / GCP** and **OpenShift** clients) is a reasonable way to **continuously reconcile** desired state instead of manual scripts or ad hoc `terraform apply`.

**Examples of what such a controller could watch and act on:**

| Signal | Possible actions |
|--------|------------------|
| **New or replaced Nodes** (Machine API, Node objects, or GCE instance lifecycle) | Ensure **`canIpForward=true`** on the backing GCE instance; add the instance to the correct zonal **unmanaged instance group** (ILB backend) **or** update **NCC Router Appliance spoke** + **Cloud Router BGP peers** + **`FRRConfiguration`** (BGP path); optionally verify labels (e.g. dedicated router pool). |
| **New or updated `ClusterUserDefinedNetwork`** (CUDN) / UDN CRs | Resolve **new overlay CIDRs**; create or update **`google_compute_route`** entries (ILB) **or** rely on **BGP advertisements** + Cloud Router import policy; widen **VPC firewall** `destination_ranges` or add rules per prefix; align **`RouteAdvertisements`** / namespaces so **conditional SNAT** matches the new network. |
| **Cluster scale or upgrade** | Reconcile ILB backends when workers join or leave **or** BGP/NCC/Cloud Router + FRR; re-apply GCE properties that **reset on replace** (see below). |

The controller would need **credentials** (for example **Workload Identity** / GCP SA with **Compute** permissions for routes, firewall, instance groups, and `instances.update` for `canIpForward`) and a **single source of truth** for which CUDN CIDRs and which node pools participate in routing.

A **Python / kopf** prototype lives in [**`controller/python/`**](controller/python/README.md) (quick-win for [PRODUCTION-ROADMAP.md § 4F](cluster_bgp_routing/PRODUCTION-ROADMAP.md)). It watches Nodes, reconciles **canIpForward**, creates/updates the **NCC spoke**, manages **Cloud Router BGP peers**, and creates/deletes **`FRRConfiguration`** CRs. Terraform manages only the **static** infrastructure (NCC hub, Cloud Router, interfaces, firewalls) — the controller owns all dynamic resources to avoid ownership conflicts on re-apply. Production path: port to Go / controller-runtime in `controller/go/`.

---

## Shared gaps (all paths)

### Worker lifecycle — GCE `canIpForward`

**`canIpForward=true`** on every worker that participates in routing. Today this is applied post-create via **`configure-routing.sh`** (gcloud export / `update-from-file`). **Replaced nodes** typically **lose** the setting until it is set again. Production needs **automated reconciliation** (controller, DaemonSet + Compute API, future OCM/GCP API support if available, or strict runbooks).

### New UDN / CUDN — OpenShift and GCP must agree

**OpenShift objects** for each overlay: namespaces / labels, **`ClusterUserDefinedNetwork`**, **`RouteAdvertisements`**, and **FRR** objects as required — kept **consistent** with the **same CIDRs** programmed in GCP (static routes and ILB next hops, or BGP-learned prefixes and firewall rules). Production usually replaces ad hoc scripts with **GitOps** or **controller-managed** objects with the same invariants.

### Architecture and isolation

**Dedicated router machine pool (optional but often desirable).** The PoC may put **all workers** in the data path and enable **`canIpForward`** broadly. Production may restrict routing to a **labeled pool** so ordinary workers are not arbitrary L3 hops.

**Multi-zone and capacity.** Plan explicit **per-zone** resources, quotas, and failure domains. For ILB, see [**cluster_ilb_routing/PRODUCTION.md**](cluster_ilb_routing/PRODUCTION.md); for BGP, NCC and Router Appliance attachment design should match your zone layout.

### Security and compliance

**Remove or harden PoC-only assets** (for example **echo VM** — optional **IAP SSH** instead of internet-wide SSH). See [Security (PoC)](cluster_ilb_routing/README.md#security-poc) and [Security (PoC)](cluster_bgp_routing/README.md#security-poc) in each reference stack README.

**Secrets** (`OSDGOOGLE_TOKEN`, admin credentials, GCP keys) belong in **secret stores**, not in VCS.

### Cross-VPC and hybrid connectivity

**Peered VPCs, VPN, and Interconnect** do not magically learn CUDN prefixes. You still need **static routes** (ILB path) or a **dynamic** design (**BGP via Cloud Router + NCC** — see [ILB-vs-BGP.md](ILB-vs-BGP.md)). Path-specific follow-through is in [**cluster_ilb_routing/PRODUCTION.md**](cluster_ilb_routing/PRODUCTION.md) and [**cluster_bgp_routing/PRODUCTION.md**](cluster_bgp_routing/PRODUCTION.md).

### Operations and drift

**Runbooks and monitoring:** ILB backend health, **NCC/BGP** session state (BGP path), VPC routes, firewall denies, **`ovn-nbctl list nat`** (or equivalent), and **end-to-end probes** from the VPC after **node** or **CUDN** changes.

**Drift:** Workers are **not** Terraform-managed resources; **only reconciling** when someone runs `terraform apply` is **fragile**. Treat **node membership**, **GCE flags**, and **path-specific GCP objects** (instance groups, spoke lists, peers) as **continuously reconciled** state.

---

**Summary:** Production requires **automation** for **`canIpForward`**, **ILB backend membership** or **BGP/NCC/peer state**, **VPC routing and firewalls** appropriate to each path, **stronger health signals** than the PoC, and **hardening**. A **controller** watching **Nodes** and **CUDN/UDN CRs** is a natural way to tie **Kubernetes intent** to **GCP networking** over the cluster lifetime. Use the stack-specific PRODUCTION docs above for concrete ILB vs BGP gaps.
