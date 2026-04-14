# Production Roadmap -- BGP CUDN Routing

Actionable checklist for moving the BGP stack from PoC to production. Read [PRODUCTION.md](../PRODUCTION.md) first for context on each gap.

Tasks are grouped into phases. Each phase ends with guidance on when to run a **full end-to-end test** (create + verify + destroy, ~2 hours). The goal is to batch related changes so you validate once per phase rather than after every individual task.

**Conventions:** `[ ]` = not started, `[x]` = done. Strike through or check items as you go.

---

## Phase 1: Safety and Correctness

Everything here should land before any non-lab traffic touches the stack. Changes in this phase are low-risk individually and mostly additive (docs, variable fixes, firewall scope).

### 1A -- Remove / gate PoC-only assets

- [x] **No open SSH from the internet.** Echo VM has **no `access_config`** (no public IP). SSH uses **Identity-Aware Proxy TCP forwarding**: **`gcloud compute ssh INSTANCE --tunnel-through-iap`**, with a firewall rule allowing **tcp:22** from **`35.235.240.0/20`** to the echo VM’s **network tags** (`google_compute_firewall.echo_client_ssh_iap`, same GCP name `*-echo-client-ssh` as before). See [`modules/osd-bgp-routing/echo_vm.tf`](../modules/osd-bgp-routing/echo_vm.tf). Enable the **IAP API** and grant operators **`iap.tunnelInstances.accessViaIAP`** (e.g. **IAP-secured Tunnel User**).
- [x] **`scripts/e2e-cudn-connectivity.sh`** and cluster README **manual `gcloud compute ssh`** examples pass **`--tunnel-through-iap`**.
- [x] Module READMEs state that **`enable_echo_client_vm`** is a **lab / validation** fixture (BGP reference stack).

### 1B -- Firewall tightening

- [x] **`worker_subnet_to_cudn_firewall_mode`** (`all` \| **`e2etest`** default \| `none`) on **`modules/osd-bgp-routing`**: **`e2etest`** allows ICMP + TCP/8080 (icanhazip test pods and echo VM host port) for documented e2e; **`all`** restores broad allow; **`none`** omits the rule (bring your own policy). Wired from **`cluster_bgp_routing/`** (`variables.tf`, `main.tf`). *(Archived ILB module mirrors the same variable.)*
- [x] **`routing_worker_target_tags`** (optional list): when non-empty, scopes **worker→CUDN** and **BGP tcp/179** (BGP module only) with GCP **`target_tags`**. Workers must be given matching **network tags** (e.g. instance template / MachineSet). Empty = subnet-wide match (lab default).
- [ ] Evaluate whether explicit **egress** rules are needed for CUDN return traffic (depends on org default-deny policy).

**State note:** the worker→CUDN rule now uses `count`; existing stacks may show a one-time destroy/create or use **`terraform state mv`** from **`google_compute_firewall.worker_subnet_to_cudn`** to **`google_compute_firewall.worker_subnet_to_cudn[0]`** inside the routing module in state (path depends on `module` address).

### 1C -- Cloud Router interface IP safety

- [x] **`reserve_cloud_router_interface_ips`** (default **true**) in [`modules/osd-bgp-routing`](../modules/osd-bgp-routing): **`google_compute_address`** INTERNAL **`GCE_ENDPOINT`** per interface IP; set **false** for brownfield if needed. See [`router_interface_ips.tf`](../modules/osd-bgp-routing/router_interface_ips.tf).
- [x] **`check` `router_interface_ips_in_worker_subnet`** — each IP must lie in the worker subnetwork primary **IPv4** CIDR (uint32 range math; no **`cidrcontains`** requirement).
- [x] Cluster root passes **`reserve_cloud_router_interface_ips`** ([`cluster_bgp_routing/variables.tf`](variables.tf), [`main.tf`](main.tf)).

### 1D -- Variable / doc fixes

- [x] Fix `router_interface_private_ips` description in [`cluster_bgp_routing/variables.tf`](variables.tf) (“exactly 2 elements”).
- [x] Pin **`hashicorp/google`** to **`>= 5.0, < 8.0`** in **`modules/osd-bgp-routing`**, **`cluster_bgp_routing/providers.tf`**, and **`wif_config/providers.tf`** (caps major 8.x until tested). *(Archived roots under **`archive/`** use the same constraint.)*

### 1E -- Terraform state backend

- [x] [docs/terraform-backend-gcs.md](../docs/terraform-backend-gcs.md) — GCS bucket, **`backend "gcs"`**, migrate, locking.
- [x] **`cluster_bgp_routing/backend.tf.example`** and pointers in **`terraform.tfvars.example`**, [PRODUCTION.md](../PRODUCTION.md), [README.md](../README.md), module READMEs, cluster BGP README.

### E2E Checkpoint -- Phase 1

> **Run a full e2e test** after completing all of Phase 1 — e.g. **`make create`** (or **`make bgp.run`**, **`make bgp.deploy-controller`**, **`make bgp.e2e`**; or **`make controller.run`** / **`controller.watch`** instead of deploy-controller), then **`make destroy`** (or **`make bgp.destroy-controller`** and **`make bgp.teardown`**; or **`make controller.cleanup`** only if you keep **`controller_gcp_iam/`**). Skip **`controller.*`** / **`bgp.destroy-controller`** / **`destroy`** only if you are not exercising the controller. This validates that firewall tightening, echo VM changes, and IP reservation haven't broken the data path. If the firewall changes are the only risky items, you can batch 1A-1E into a single test cycle.

---

## Phase 2: Operational Foundations

These items make the stack survivable on day 2 -- worker replacement procedures, BGP tuning, IAM lockdown. Land them before scaling beyond a small pilot.

### 2A -- Worker lifecycle and controller operations (documented)

With the [**BGP routing controller**](../controller/python/README.md) owning **NCC spoke**, **BGP peers**, **`canIpForward`**, and **`FRRConfiguration`**, runbooks should describe **controller-first** recovery — not **`terraform apply`** for those objects (Terraform owns **static** infra only).

- [ ] Runbook: **healthy controller** — worker replaced or scaled: what the controller does automatically, how to verify (GCP: spoke + peers + `canIpForward`; cluster: `FRRConfiguration`, BGP session), expected convergence time and blast radius.
- [ ] Runbook: **controller down / degraded** — safe order to restart **`bgp.deploy-controller`**, check WIF **Secret** and **ConfigMap**, temporary mitigations if the **Deployment** cannot run.
- [ ] Runbook: **emergency** — remove a node from routing (cordone/drain expectations, whether to scale the **Deployment** to zero before manual GCP edits, documenting when **not** to hand-edit spoke/peer state).
- [ ] Document residual gaps: **`configure-routing.sh`** is still **one-time / CUDN CR** setup (not per-node); new **CUDN CIDRs** need **Terraform + OpenShift** alignment until Phase **3A** (multiple CUDN support) lands.

### 2B -- BGP session tuning

- [ ] Set explicit `keepalive_interval` (e.g., 20) on each `google_compute_router_peer` (Cloud Router default is 20s keep / 60s hold; make it explicit so it survives provider-default changes).
- [ ] Evaluate BFD for sub-second failure detection. If enabled, add `bfd { session_initialization_mode = "ACTIVE" }` on peers. Document trade-offs (faster failover vs flap sensitivity).
- [ ] Document the chosen `advertised_route_priority` strategy: ECMP (equal priority across all workers, the current implicit default) vs active/standby.

### 2C -- IAM least-privilege

- [ ] Define exact GCP permissions needed (not just role names) for the Terraform principal. Document as a custom role definition JSON or a list of `resourcemanager.projects.setIamPolicy`-safe permissions.
- [ ] Separate "deploy" (create/destroy NCC, Cloud Router, peers) from "operate" (update spoke instances, update peers) permission sets.
- [ ] Document whether the OSD WIF SA can be extended or whether a separate SA is needed.

### 2D -- Secrets management

- [ ] Document how to source `ocm_token` from GCP Secret Manager or Vault instead of env vars / tfvars.
- [ ] Ensure `admin_password` is either auto-generated (current default) or pulled from a secret store. Remove any pattern that encourages putting it in `terraform.tfvars`.
- [ ] Confirm backend encryption is enabled on the state bucket (GCS default encryption or CMEK).

### 2E -- ASN governance

- [ ] Document ASN allocation policy: which ranges are safe, how to avoid conflicts with other Cloud Routers in the org.
- [ ] Add a `check` block validating `cloud_router_asn` and `frr_asn` are in RFC 6996 private range and are not equal to each other.

### E2E Checkpoint -- Phase 2

> **Run a full e2e test** after Phase 2. Focus on: (1) BGP sessions come up with explicit keepalive/BFD settings, (2) firewall rules from Phase 1 still pass, (3) **with the controller running**, worker replacement or scale events reconcile within your documented SLO (simulate node churn; validate runbooks). This cycle validates the operational model.

---

## Phase 3: Multi-CUDN and Observability

These items unlock **dynamic multi-CIDR** routing (without static per-prefix VPC routes for each overlay) and add the monitoring needed to operate confidently.

### 3A -- Multiple CUDN support

- [ ] Change `cudn_cidr` (string) to `cudn_cidrs` (list of strings) in `modules/osd-bgp-routing` variables; keep `cudn_cidr` as a deprecated alias for backward compatibility.
- [ ] Update `worker_subnet_to_cudn` firewall `destination_ranges` to use the list.
- [ ] Update `configure-routing.sh` to accept multiple `--cudn-cidr` values and create a `ClusterUserDefinedNetwork` per CIDR (or a single CUDN with multiple subnets, depending on OVN-K support).
- [ ] Update `RouteAdvertisements` network selectors to match all CUDNs.
- [ ] Document the expected behavior: new CIDRs advertised automatically via FRR once the CUDN + RouteAdvertisements are aligned.

### 3B -- Monitoring and alerting

- [ ] Create a Cloud Monitoring dashboard (or Terraform `google_monitoring_dashboard`) for:
  - BGP session status per peer (`router/bgp/session_up`)
  - Received/advertised route counts (`router/bgp/received_routes_count`)
  - NCC spoke state
- [ ] Define alerting policies for BGP session down (per peer) and route count drop to zero.
- [ ] Add an end-to-end probe (CronJob or external uptime check) that periodically curls from a VPC host to a CUDN pod IP, alerting on failure.

### 3C -- Drift detection (lightweight)

- [ ] Script (or CI job) that compares: actual GCE instances with `-worker-` in name vs NCC spoke attachment list vs `FRRConfiguration` CRs. Report mismatches.
- [ ] Script that verifies `canIpForward=true` on all router-appliance instances.
- [ ] Script that verifies dynamic VPC routes exist for each expected CUDN CIDR.

### 3D -- Cloud Router route policy

- [ ] Evaluate and document `advertise_mode` on `google_compute_router.bgp` (default vs custom).
- [ ] If cross-VPC/VPN propagation is needed, document the HA VPN + Cloud Router pattern and the `ncc_spoke_site_to_site_data_transfer` flag behavior.

### E2E Checkpoint -- Phase 3

> **Run a full e2e test** with **two CUDNs** (e.g., `10.100.0.0/16` and `10.101.0.0/16`). Verify both CIDRs appear as dynamic VPC routes, both are reachable from VPC hosts, and monitoring dashboards show healthy sessions. This validates the **multi-CIDR** BGP path end to end.

---

## Phase 4: Architecture and Scale (Mature Production)

These items are for scaling beyond a pilot. They involve larger structural changes and can be done incrementally.

### 4A -- Dedicated router node pool

- [ ] Design: optional labeled machine pool with smaller instance types dedicated to routing. The controller selects **candidates** via **`NODE_LABEL_KEY`** / **`NODE_LABEL_VALUE`** (default worker label) and marks chosen routers with **`ROUTER_LABEL_KEY`** (default **`cudn.redhat.com/bgp-router`**); point these at a dedicated pool when you split routers from general workers.
- [x] Controller watches Nodes by label, discovers GCE instances via `providerID`, reconciles `canIpForward`, NCC spoke, BGP peers, and `FRRConfiguration` CRs.
- [ ] Document cost/performance trade-offs (fewer hops vs dedicated instances; infra-shared vs isolated routers).

### 4B -- Worker discovery improvements

- [x] **Terraform no longer discovers workers.** The controller uses Kubernetes Node `providerID` and the GCP Compute API to discover instances — no `data.external` or `gcloud`/`jq` dependency at plan time.
- [x] **BGP peers managed by controller.** No `for_each` vs `count` concerns — the controller computes the desired peer set and patches the Cloud Router directly.

### 4C -- Multi-zone support

- [x] Update `availability_zone` (string) to `availability_zones` (list) in `cluster_bgp_routing/variables.tf` (for the default worker pool; Cloud Router is regional and zone-agnostic).
- [x] **Controller is zone-agnostic:** discovers zones from `Node.spec.providerID` — no script changes needed for multi-zone.
- [ ] Verify Cloud Router (regional) handles multi-zone peers correctly (expected: yes).
- [ ] Test zone-failure scenario: cordon all nodes in one zone, verify routes withdraw and traffic shifts.

### 4D -- Cloud Router HA

- [ ] Document current HA posture: 2 interfaces (primary + redundant) is the GCP-recommended Router Appliance pattern.
- [ ] Evaluate whether a second Cloud Router (active/active) adds value beyond the built-in HA pair.
- [ ] Test interface failover: what happens when one interface loses all its peers? How fast does traffic converge?

### 4E -- Terraform module hardening

- [ ] Add `lifecycle { prevent_destroy = true }` on NCC hub and Cloud Router (prevent accidental teardown).
- [ ] Add `moved` blocks for any planned resource renames (future-proofing).
- [ ] Add `terratest` or similar integration test scaffolding.
- [ ] Add `shellcheck` linting for all scripts in CI.

### 4F -- Full automation (controller)

- [x] Design doc: Kubernetes controller watching Node objects, reconciling GCP state (canIpForward, NCC spoke, Cloud Router peers) and OpenShift state (FRRConfiguration CRs).
- [x] **Quick-win prototype:** Python / kopf controller in [`controller/python/`](../../controller/python/README.md) — watches Nodes with configurable label selector, reconciles all 4 dynamic resources (canIpForward, NCC spoke, Cloud Router peers, FRRConfiguration), debounced event + periodic drift loop, WIF for GCP credentials. Deployment manifests in `deploy/` (kustomize).
- [x] **Controller owns dynamic resources:** Terraform refactored to only manage static infra (hub, router, interfaces, firewalls). Controller creates NCC spoke on first reconciliation and fully owns spoke instances, BGP peers, canIpForward, and FRRConfiguration CRs. No ownership conflict with Terraform on re-apply.
- [ ] Validate kopf controller in a live cluster (node replacement, scale-up, scale-down).
- [ ] **Production:** port reconciliation logic to Go / controller-runtime; add `BGPRoutingConfig` CRD for operator-owned configuration; OLM bundle (`controller/go/`).
- [ ] Define leader election, error handling, rate limiting, and credential management (kopf prototype uses threading + debounce; Go version uses controller-runtime leader election).

### E2E Checkpoint -- Phase 4

> **Run a full e2e test** after each major sub-phase (4A, 4C, and 4F are the biggest). For 4C (multi-zone), include a zone-failure simulation. For 4F (controller), test the full lifecycle: create cluster, replace a worker (trigger Machine API), verify the controller reconciles within SLA without manual intervention.

---

## Capacity and Limits Reference

Document and validate these limits before scaling:

- [ ] Cloud Router: max BGP peers per router (default 128; requestable increase)
- [ ] Cloud Router: max learned routes (default 200 per region; requestable)
- [ ] NCC spoke: max router appliance instances per spoke (check current GCP quotas)
- [ ] FRR: max neighbors per node (practical limit with frr-k8s)
- [ ] VPC: max dynamic routes per network

---

## Summary of E2E Test Checkpoints

| After     | What to validate                                                                 | Estimated time |
|-----------|----------------------------------------------------------------------------------|----------------|
| Phase 1   | Tightened firewalls + IP reservation haven't broken data path                    | ~2 hours       |
| Phase 2   | BGP tuning, worker replacement runbook, IAM changes work end-to-end              | ~2 hours       |
| Phase 3   | Multi-CUDN routing, monitoring dashboards, drift detection                       | ~2 hours       |
| Phase 4A  | Dedicated router pool works (if implemented)                                     | ~2 hours       |
| Phase 4C  | Multi-zone + zone-failure simulation                                             | ~2.5 hours     |
| Phase 4F  | Controller-driven reconciliation (full lifecycle)                                | ~3 hours       |

Total: **6 full e2e cycles** across the entire roadmap (more if you split Phase 4 sub-items). Phases 1-3 are the critical path; Phase 4 is incremental.
