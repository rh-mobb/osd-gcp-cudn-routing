# Production readiness

This repository is a **proof of concept**. Nothing here is presented as production-ready.

This file is the **single** production-readiness guide for the **BGP** reference stack ([`cluster_bgp_routing/`](cluster_bgp_routing/README.md)). The **actionable phased checklist** is [**cluster_bgp_routing/PRODUCTION-ROADMAP.md**](cluster_bgp_routing/PRODUCTION-ROADMAP.md).

## Current state (BGP path)

- **Terraform** provisions **static** GCP pieces: NCC **hub**, **Cloud Router** (two interfaces), reservations, and **firewalls**. It does **not** own the NCC **spoke**, **BGP peers**, **`canIpForward`**, or **`FRRConfiguration`** CRs.
- The [**Python / kopf BGP routing controller**](controller/python/README.md) reconciles those **dynamic** resources from **Node** `providerID` and cluster config (WIF-backed GCP API + OpenShift client). Deploy end-to-end with **`make bgp.deploy-controller`** after **`make bgp.run`** (see root [README](README.md)).
- **[`cluster_bgp_routing/scripts/configure-routing.sh`](cluster_bgp_routing/scripts/configure-routing.sh)** is a **one-time** OpenShift step (FRR / route advertisements, **ClusterUserDefinedNetwork**, **RouteAdvertisements**). Run it **before** the controller so FRR can reconcile controller-created **`FRRConfiguration`** objects. With **`PodNetwork`** advertised, **RouteAdvertisements** must use **`nodeSelector: {}`** per OVN-K validation ([references/fix-bgp-ra.md](references/fix-bgp-ra.md) Phase 2).
- **Roadmap [Phase 1](cluster_bgp_routing/PRODUCTION-ROADMAP.md)** (safety, firewall modes, router IP reservation, backend docs) is largely **complete**. **Phases 2–4** cover runbooks, BGP tuning, IAM/secrets hardening, multi-CUDN, observability, multi-zone, and a **production-grade** controller (Go / **controller-runtime**).

**ILB** reference material is **historical** and lives only under [**`archive/`**](archive/README.md) (including [archive/cluster_ilb_routing/PRODUCTION.md](archive/cluster_ilb_routing/PRODUCTION.md) and [archive/ILB-vs-BGP.md](archive/ILB-vs-BGP.md)).

For PoC limits on the **active** stack, see [Known limitations (BGP)](cluster_bgp_routing/README.md#known-limitations).

## Terraform state

Use **remote state** (for example **GCS** with versioning and locking) for anything beyond a single-developer lab. See [docs/terraform-backend-gcs.md](docs/terraform-backend-gcs.md) and **`cluster_bgp_routing/backend.tf.example`**.

---

## BGP routing controller (implemented prototype)

Ongoing reconciliation for **node churn** is implemented by the [**Python / kopf** controller](controller/python/README.md) ([roadmap § 4F](cluster_bgp_routing/PRODUCTION-ROADMAP.md)): **WIF**-authenticated GCP + OpenShift clients, **`make bgp.deploy-controller`** ([`scripts/bgp-deploy-controller-incluster.sh`](scripts/bgp-deploy-controller-incluster.sh)) applying [**`controller_gcp_iam/`**](controller_gcp_iam/README.md) and credentials. **Production** still needs the roadmap items (Go / **controller-runtime**, CRDs, leader election, live validation).

| Area | Today (prototype) | Still manual / future |
|------|-------------------|------------------------|
| **Nodes** | **`canIpForward`**, NCC **spoke**, **Cloud Router peers**, **`FRRConfiguration`** per selected router node | Dedicated router pool tuning, stricter SLOs |
| **CUDN / overlays** | **`configure-routing.sh`** + Terraform **`cudn_cidr`** / firewalls | Multi-CIDR ([roadmap Phase 3](cluster_bgp_routing/PRODUCTION-ROADMAP.md)), GitOps or a controller watching **CUDN** CRs, firewall alignment |
| **Upgrades / scale** | Reconciliation loop + periodic drift pass | Org-grade monitoring and runbooks ([roadmap Phase 2](cluster_bgp_routing/PRODUCTION-ROADMAP.md)) |

---

## Cross-cutting gaps

### Worker lifecycle — GCE `canIpForward`

**`canIpForward=true`** on every GCE instance that acts as a **router appliance** for this design. The **BGP controller** sets this via the Compute API when a node is selected for BGP. **If the controller is down** or misconfigured, new or replaced nodes may **not** get the flag in time — production needs **monitoring**, **SLOs**, and **runbooks** (see roadmap Phase 2).

### New UDN / CUDN — OpenShift and GCP must agree

**OpenShift objects** for each overlay: namespaces / labels, **`ClusterUserDefinedNetwork`**, **`RouteAdvertisements`**, and **FRR** objects as required — kept **consistent** with the **same CIDRs** programmed in GCP (BGP-learned prefixes and firewall rules). Production usually replaces ad hoc scripts with **GitOps** or **controller-managed** objects with the same invariants.

### Architecture and isolation

**Dedicated router machine pool (optional but often desirable).** The controller selects a **bounded** set of worker nodes (defaults and labels: [controller/python/README.md](controller/python/README.md)). Production may move to a **dedicated** labeled pool so ordinary workers are not router appliances.

**Multi-zone and capacity.** Plan explicit **per-zone** resources, quotas, and failure domains. NCC and Router Appliance attachment design should match your zone layout and worker distribution (see also [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md)).

### Security and compliance

**Remove or harden PoC-only assets** (for example **echo VM** — internal-only + **IAP** SSH in the BGP module). See [Security (PoC)](cluster_bgp_routing/README.md#security-poc) in the BGP reference README.

**Secrets** (`OSDGOOGLE_TOKEN`, admin credentials, GCP keys) belong in **secret stores**, not in VCS.

### Cross-VPC and hybrid connectivity

**Peered VPCs, VPN, and Interconnect** do not magically learn CUDN prefixes. This repo’s **BGP + NCC + Cloud Router** path learns **advertised** overlay prefixes dynamically. Validate **end-to-end** whenever hub/spoke or **Cloud Router** attachments change; hybrid patterns are tracked in the [roadmap](cluster_bgp_routing/PRODUCTION-ROADMAP.md) (for example Phase 3D).

### Operations and drift

**Runbooks and monitoring:** **NCC/BGP** session state, VPC routes, firewall denies, **`ovn-nbctl list nat`** (or equivalent), and **end-to-end probes** from the VPC after **node** or **CUDN** changes.

**Drift:** Worker VMs are **not** Terraform-managed; the **controller** should keep **NCC spoke membership**, **BGP peers**, **`canIpForward`**, and **FRR** aligned with **live Nodes**. Terraform **re-apply** alone does not fix node churn — monitor controller health and use roadmap **drift-detection** items when you operationalize.

---

## BGP-specific gaps

**IAM:** Terraform principals — [Requirements § IAM](modules/osd-bgp-routing/README.md#requirements). Controller service account — [`controller_gcp_iam/`](controller_gcp_iam/README.md) and [`modules/osd-bgp-controller-iam/`](modules/osd-bgp-controller-iam/README.md). Historical role comparison: [archive/ILB-vs-BGP.md](archive/ILB-vs-BGP.md).

1. **NCC spoke, Cloud Router peers, canIpForward, and FRRConfiguration** are managed by the [BGP routing controller](controller/python/README.md). The controller must be deployed and healthy for routing to converge after node changes. Production should validate the controller in a live cluster (node replacement, scale-up, scale-down) and consider porting to Go / controller-runtime for production hardening (see [PRODUCTION-ROADMAP.md § 4F](cluster_bgp_routing/PRODUCTION-ROADMAP.md)).

2. **Per-node `FRRConfiguration`:** The controller creates one CR per router node, matching GCE instance names from **`Node.spec.providerID`**. Production may prefer a Go controller with a `BGPRoutingConfig` CRD for operator-owned configuration.

3. **Cloud Router interface IPs:** Default allocation uses **`cidrhost(subnet, offset + index)`**; collisions with other hosts must be prevented (override **`router_interface_private_ips`** in Terraform if needed).

4. **IAM (detail):** Principals applying [**`modules/osd-bgp-routing`**](modules/osd-bgp-routing/README.md) need **NCC hub admin** and **network admin** roles. The **controller** uses Terraform [**`controller_gcp_iam/`**](controller_gcp_iam/README.md) (module [**`modules/osd-bgp-controller-iam/`**](modules/osd-bgp-controller-iam/README.md)) plus [`scripts/bgp-controller-gcp-credentials.sh`](scripts/bgp-controller-gcp-credentials.sh); see [controller/python/README.md](controller/python/README.md).

5. **ASN policy, session monitoring, BFD:** Production should define **allowed ASNs**, **hold timers**, and **observability** for BGP sessions (beyond what the PoC demonstrates). Align with your org's **Network Connectivity Center** standards.

6. **Peered VPCs, VPN, Interconnect:** Remote networks do not automatically learn CUDN prefixes. With BGP, routes propagate via **Cloud Router** import policy and **NCC** topology; validate **end-to-end** whenever hub/spoke or **Cloud Router** attachments change (see also [Cross-VPC and hybrid connectivity](#cross-vpc-and-hybrid-connectivity) above).

---

**Summary:** Production still requires **stronger operations** (runbooks, monitoring, IAM/secrets, multi-CIDR) than this PoC, even though **node-level** BGP state is **controller-reconciled** today. Use [**cluster_bgp_routing/PRODUCTION-ROADMAP.md**](cluster_bgp_routing/PRODUCTION-ROADMAP.md) for phased work and checkpoints.
