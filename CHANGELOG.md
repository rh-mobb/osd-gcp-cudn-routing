# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **BGP routing controller (Python / kopf):** [`controller/python/`](controller/python/README.md) — watches Nodes with a configurable label selector (default **`node-role.kubernetes.io/infra`**), reconciles **canIpForward**, **NCC spoke** (creates if missing), **Cloud Router BGP peers**, and **`FRRConfiguration`** CRs on node create / replace / delete. Debounced event-driven + periodic drift loop. GCP auth via WIF credential config. Deployment manifests under `deploy/` (kustomize). Quick-win prototype for [PRODUCTION-ROADMAP.md § 4F](cluster_bgp_routing/PRODUCTION-ROADMAP.md).

### Changed

- **README:** BGP [quick start](README.md#quick-start--bgp) now includes **`make controller.venv`** / **`make controller.run`** (and pointers to **`controller.watch`** and in-cluster deploy) so the Python BGP controller is explicit after **`make bgp-apply`**; Makefile summary lists **`controller.*`** targets.

- **Controller owns dynamic resources:** NCC spoke, Cloud Router BGP peers, `canIpForward`, and `FRRConfiguration` CRs are now managed exclusively by the controller (`controller/python/`). Terraform manages only the **static** infrastructure (NCC hub, Cloud Router, interfaces, firewalls). This avoids ownership conflicts between Terraform and the controller on re-apply.

  **Breaking changes from previous unreleased state:**
  - `modules/osd-bgp-routing`: removed `google_network_connectivity_spoke`, `google_compute_router_peer` resources, and `var.router_instances`. New outputs: `ncc_hub_name`, `ncc_spoke_name`, `cloud_router_asn`, `frr_asn`, `ncc_spoke_site_to_site_data_transfer`. Removed outputs: `ncc_spoke_id`, `bgp_peer_matrix`.
  - `cluster_bgp_routing`: removed `data.external "workers"`, all discovery locals, `var.bgp_router_instance_name_regex`, and worker-related outputs (`worker_instances`, `bgp_peer_matrix`, `bgp_router_instance_name_regex`). New outputs: `ncc_hub_name`, `ncc_spoke_name`, `cloud_router_name`. Single-pass apply (no two-phase worker wait).
  - Deleted scripts: `discover-workers.sh`, `enable-worker-can-ip-forward.sh`.
  - `configure-routing.sh` is now one-time setup only (FRR enable, CUDN, RouteAdvertisements) — no longer manages `canIpForward` or `FRRConfiguration`.
  - `bgp-apply.sh` simplified: WIF → single Terraform apply → oc login → configure-routing.sh. No worker wait loop or canIpForward step.

- **BGP reference stack (`cluster_bgp_routing`):** default **`compute_machine_type`** is **`n2-standard-4`** (typical osd-cluster worker default); **`data.osdgoogle_machine_types`** renamed to **`osd_catalog`**. **`cluster_ilb_routing`** gets the same default machine type and **`osd_catalog`** rename.

### Added

- **Cloud Router interface IP reservations:** **`reserve_cloud_router_interface_ips`** (default **true**) in **`modules/osd-bgp-routing`** — two **`google_compute_address`** resources (INTERNAL **`GCE_ENDPOINT`**) so interface IPs are not taken by other GCE resources; wired from **`cluster_bgp_routing`**. New file **`router_interface_ips.tf`**. **`check`** **`router_interface_ips_in_worker_subnet`** validates IPs lie in the worker subnet CIDR.
- **Terraform remote state:** [docs/terraform-backend-gcs.md](docs/terraform-backend-gcs.md); **`cluster_bgp_routing/backend.tf.example`**, **`cluster_ilb_routing/backend.tf.example`**; cross-links in [PRODUCTION.md](PRODUCTION.md), [README.md](README.md), cluster READMEs, **`terraform.tfvars.example`** files, and ILB/BGP module READMEs. [PRODUCTION-ROADMAP.md](cluster_bgp_routing/PRODUCTION-ROADMAP.md) Phase 1C / 1D / 1E items marked done.

- **`cluster_bgp_routing/PRODUCTION-ROADMAP.md`** -- phased, checkboxed roadmap for BGP production readiness: safety/correctness (Phase 1), operational foundations (Phase 2), multi-CUDN and observability (Phase 3), architecture and scale (Phase 4); includes e2e test checkpoint guidance between phases. Linked from [cluster_bgp_routing/PRODUCTION.md](cluster_bgp_routing/PRODUCTION.md) and root [PRODUCTION.md](PRODUCTION.md).

### Fixed

- **Controller `clear_peers` was a no-op:** `gcp.py` used `RoutersClient.patch()` with an empty `bgp_peers` list, but proto3 serialization omits empty repeated fields — the API silently ignored the change. Switched to `RoutersClient.update()` (PUT) which replaces the full resource and correctly clears the peers. This also caused `controller.cleanup` and `bgp-destroy` to leave BGP peers behind, blocking GCE instance deletion.
- **`bgp-destroy.sh` did not clean up controller-managed resources:** added `make -C controller/python cleanup` step before `terraform destroy` so that BGP peers, NCC spoke, and FRR CRs are removed before Terraform tries to delete the backing instances.

- **`check` `router_interface_ips_in_worker_subnet`** in **`modules/osd-bgp-routing`** — avoid **`cidrcontains`** (Terraform **1.8+** only); use IPv4 **uint32** range comparison so older Terraform (**`make bgp-apply`**) works.

- **`cluster_bgp_routing/variables.tf`** -- `router_interface_private_ips` description corrected from "same length as workers" to "exactly 2 elements" (matches module `check` block).

### Changed

- **`hashicorp/google`** provider constraint is **`>= 5.0, < 8.0`** in **`modules/osd-bgp-routing`**, **`modules/osd-ilb-routing`**, **`cluster_ilb_routing`**, **`cluster_bgp_routing`**, and **`wif_config`** (replaces open-ended **`>= 5.0`**).

- **Worker subnet → CUDN firewall:** new **`worker_subnet_to_cudn_firewall_mode`** (`all` \| **`e2etest`** default \| `none`) and **`routing_worker_target_tags`** (optional GCP **`target_tags`** for router/ILB workers) in **`modules/osd-bgp-routing`**, **`modules/osd-ilb-routing`**, and both **`cluster_*_routing/`** stacks. **`e2etest`** allows ICMP + TCP/80 for **`make *-e2e`**. BGP **`tcp/179`** rule uses tags when the list is non-empty (subnet `destination_ranges` when empty). Debug script tolerates missing CUDN firewall when **`none`**. [PRODUCTION-ROADMAP.md](cluster_bgp_routing/PRODUCTION-ROADMAP.md) § 1B updated. Existing state: resource address is now **`worker_subnet_to_cudn[0]`** — expect a one-time replace or run **`terraform state mv`** inside the module if you want to avoid recreation.

- **Echo VM (`modules/osd-ilb-routing`, `modules/osd-bgp-routing`):** no public IP; SSH ingress limited to IAP TCP forwarding (**`35.235.240.0/20`**, **`gcloud compute ssh --tunnel-through-iap`**). Replaces **`0.0.0.0/0`** SSH. Output **`echo_client_vm_external_ip`** is always **`null`**. Terraform **`moved`** from **`google_compute_firewall.echo_client_ssh_public`** to **`echo_client_ssh_iap`** (same GCP rule name **`*-echo-client-ssh`**). **`scripts/e2e-cudn-connectivity.sh`**, cluster READMEs, [PRODUCTION.md](PRODUCTION.md), and [PRODUCTION-ROADMAP.md](cluster_bgp_routing/PRODUCTION-ROADMAP.md) § Phase 1A updated.

- **`deploy-cudn-test-pods.sh`** — single implementation under [`scripts/deploy-cudn-test-pods.sh`](scripts/deploy-cudn-test-pods.sh); **`cluster_ilb_routing/scripts/`** and **`cluster_bgp_routing/scripts/`** wrappers **`exec`** the shared script.
- **Docs:** root [README.md](README.md) **§ Shared prerequisites** — minimum **`TF_VAR_gcp_project_id`** / **`TF_VAR_cluster_name`** (or **`terraform.tfvars`** from **`terraform.tfvars.example`**) before apply; cluster **§ Variables and apply order** repeats this + **`.example`** for other settings. **Quick start** / **One-shot** flow (**`make ilb-e2e`** / **`make bgp-e2e`**, teardown, etc.) unchanged aside from cross-links.

### Added

- **`Makefile`** — **`ilb-e2e`** and **`bgp-e2e`** run **`scripts/e2e-cudn-connectivity.sh`** with **`-C cluster_ilb_routing/`** or **`-C cluster_bgp_routing/`**; [**README.md**](README.md) quick starts and cluster READMEs recommend them after **`make ilb-apply`** / **`make bgp-apply`**; **`configure-routing.sh`** / **`ilb-apply.sh`** / **`bgp-apply.sh`** completion messages mention **`make ilb-e2e`** / **`make bgp-e2e`**.
- **`scripts/e2e-cudn-connectivity.sh`** — shared end-to-end test: runs **`deploy-cudn-test-pods.sh`**, **pod → echo VM** (**`ping`** + **`curl`** with body check against netshoot CUDN IP), **echo VM → pod** (**`ping`** + **`curl`** to **`icanhazip-cudn`** with body check against VM IP). **`--cluster-dir`**, **`--namespace`**, **`--skip-deploy`**, **`--allow-icmp-fail`**, **`--ping-iface`**. Documented in [scripts/README.md](scripts/README.md) and cluster READMEs.
- **`cluster_bgp_routing/scripts/debug-gcp-bgp.sh`** — **`gcloud`** diagnostics for BGP (**`routers get-status`** / **describe**), NCC hub and regional spoke, VPC routes for **`cudn_cidr`**, and **`osd-bgp-routing`** firewall rules; uses **`terraform output -json`** from **`cluster_bgp_routing/`**. Documented in [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md) and [scripts/README.md](scripts/README.md).

### Fixed

- **`scripts/e2e-cudn-connectivity.sh`** — avoid **`${DEPLOY_EXTRA_ARGS[@]}`** when empty so **`set -u`** does not fail on **Bash 3.2** (macOS default); strip **`@ifN`** from **`ip -br`** ifnames so **`ping -I`** uses **`ovn-udn1`**, not **`ovn-udn1@if35`** (**`SO_BINDTODEVICE`**); log each step with a leading **`+`** (shell-escaped, like **`set -x`**) and print **curl** response bodies (pod → VM and VM → pod); **`print_cmd_line`** writes entirely to **stderr** so **`$(discover_ping_iface …)`** does not capture trace output as the iface name; **ANSI** highlights (**`NO_COLOR`** / **`FORCE_COLOR`**), **`[ PASS ]` / `[ WARN ]` / `[ FAIL ]`**, numbered steps, and a short **Summary** table.

- **`cluster_bgp_routing/scripts/configure-routing.sh`** — append **`spec.raw`** FRR (**`neighbor … disable-connected-check`**) for each Cloud Router IP so BGP can establish when workers use a **GCP-style /32** on **br-ex** (FRR otherwise reports **No path to specified Neighbor** while **`nc` to tcp/179** works); **`ebgpMultiHop`** on typed neighbors is omitted because MetalLB admission rejects it when merged with **`ovnk-generated-*`** **`FRRConfiguration`** objects.
- **BGP / Cloud Router:** redesigned to match GCP Router Appliance architecture — exactly **2 Cloud Router interfaces** (primary + redundant HA pair) with **2 BGP peers per worker** (one on each interface). Previously the module created one interface per worker with mutual `redundant_interface` references, which failed with API **400** *does not have a redundant interface*. `configure-routing.sh` now creates **`FRRConfiguration`** with **2 neighbors** per worker. `router_interface_private_ips` now expects exactly **2 elements** (not N).

### Changed

- **Documentation:** [README.md](README.md) **Roadmap / TODO** — future **dedicated routing nodes** for BGP (vs workers-as-router-appliances).

- **Documentation:** root [README.md](README.md) is a short overview (problem, shared prerequisites, ILB/BGP TL;DR, quick starts, Makefile summary, doc index). Detailed architecture, deployment, verification, teardown, and troubleshooting live in [cluster_ilb_routing/README.md](cluster_ilb_routing/README.md) and [cluster_bgp_routing/README.md](cluster_bgp_routing/README.md). [PRODUCTION.md](PRODUCTION.md) links updated to those sections.
- **Production docs:** [PRODUCTION.md](PRODUCTION.md) is the **shared** overview (controller, cross-cutting gaps, ops). Path-specific checklists are [cluster_ilb_routing/PRODUCTION.md](cluster_ilb_routing/PRODUCTION.md) and [cluster_bgp_routing/PRODUCTION.md](cluster_bgp_routing/PRODUCTION.md).

### Added

- **`modules/osd-bgp-routing`** — NCC hub, Router Appliance spoke, Cloud Router, per-worker BGP peers, firewalls (worker subnet → CUDN, BGP **tcp/179**), optional echo VM; outputs **`bgp_peer_matrix`** for **`configure-routing.sh`**.
- **`cluster_bgp_routing/`** — reference root module (VPC + OSD cluster + BGP module); **`enable_bgp_routing`** two-phase apply; BGP-specific **`scripts/`** (including **`discover-workers.sh`** with **`networkIP`**, **`configure-routing.sh`** with per-node **`FRRConfiguration`**).
- **`make bgp-apply`** / **`make bgp-destroy`** and **`scripts/bgp-apply.sh`** / **`scripts/bgp-destroy.sh`**; Makefile **`bgp.init`**, **`bgp.plan`**, **`bgp.apply`**, **`bgp.destroy`** for **`cluster_bgp_routing/`**; **`make validate`** includes the BGP stack.
- **Docs:** root **README.md** (ILB + BGP paths, quick start, teardown, layout), **ILB-vs-BGP.md** (Approach B implemented; migration path points at new module/stack), **PRODUCTION.md** (BGP production notes), **scripts/README.md** (**`BGP_APPLY_*`** env vars).

- **`PRODUCTION.md`** — production-readiness gaps (workers, ILB backends, CUDN/VPC routes, health checks, security, ops); **Kubernetes controller** reconciliation concept (watch **Nodes**, **CUDN** CRs, drive GCP + OpenShift alignment).
- **`cluster_ilb_routing/README.md`** — reference stack overview, pointers to root docs, inputs and apply order.
- **`scripts/README.md`** — `ilb-apply` / `ilb-destroy` environment variables and Terraform arg passthrough.

- **`cluster_ilb_routing/scripts/deploy-cudn-test-pods.sh`** — applies **netshoot-cudn** and **icanhazip-cudn**, **`oc wait`** for Ready, optional **`-n` / `--namespace`** (default **`cudn1`**), **`--timeout`**, **`--no-wait`**; see [cluster_ilb_routing/README.md § End-to-end checks](cluster_ilb_routing/README.md#end-to-end-checks).

- **`cluster_ilb_routing/scripts/cudn-pod-ip.sh`** — resolves the **primary UDN / CUDN** IP from OVN annotations (**`k8s.ovn.org/pod-networks`**, then **`k8s.v1.cni.cncf.io/network-status`**), with **`status.podIPs`** prefix match last; optionally checks **`terraform output -raw cudn_cidr`** prefix.

- **`google_compute_firewall.worker_subnet_to_cudn`** — allows **all protocols** **from** the worker subnetwork (data source on **`subnet_id`**) **to** **`cudn_cidr`** so hosts on the worker subnet (echo VM, jump boxes) can reach CUDN workloads via the ILB; complements **`osd-vpc` `cluster-internal`** (which does not include CUDN prefixes in **`destination_ranges`**).

- **README** (root quick start — ILB) — **`make ilb-apply`**; detailed checks in [cluster_ilb_routing/README.md § End-to-end checks](cluster_ilb_routing/README.md#end-to-end-checks).
- **icanhazip-cudn** pod manifest in **§7** (same image as the echo VM; VM / VPC can **`curl http://<pod-ip>/`**).
- **`make ilb-apply`** / **`make ilb-destroy`** and **`scripts/ilb-apply.sh`** / **`scripts/ilb-destroy.sh`** — end-to-end WIF, two-pass cluster apply (ILB + echo VM on pass 2), worker wait loop, `oc login`, and **`configure-routing.sh`**; destroy cluster stack then WIF (`-auto-approve` on Terraform).
- Initial repository: ILB-based CUDN routing module (`modules/osd-ilb-routing`) and
  reference deployment (`cluster_ilb_routing/`), moved from
  [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google).

### Fixed

- **`make ilb-apply`** / **`make bgp-apply`:** skip **pass-1** cluster **`terraform apply`** when **`module.ilb_routing[0]`** / **`module.bgp_routing[0]`** is already in Terraform state, so re-running the orchestration no longer applies default **`enable_*_routing=false`** and destroys pass-2 resources. Override with **`ORCHESTRATION_FORCE_PASS1=1`**. Shared probe in **`scripts/orchestration-lib.sh`**.
- **`make bgp-apply` / NCC spoke:** enable **`canIpForward`** on workers **before** the second Terraform apply. GCP rejects **`google_network_connectivity_spoke`** router-appliance instances unless **`canIpForward`** is already **true** (previously **`configure-routing.sh`** ran only after apply). Added **`cluster_bgp_routing/scripts/enable-worker-can-ip-forward.sh`** and **`bgp-apply.sh`** step **3b**; **`configure-routing.sh`** reuses the same helper (zone from **`terraform output availability_zone`**).
- **`cudn-pod-ip.sh`**: read the primary UDN IP from **`k8s.ovn.org/pod-networks`** and **`k8s.v1.cni.cncf.io/network-status`**; **`status.podIPs`** in OVN-K stays on the infrastructure network for primary-UDN pods, so the CUDN address may not appear there ([OVN-K docs](https://ovn-kubernetes.io/features/user-defined-networks/user-defined-networks/)).

- **`data.google_compute_subnetwork.worker`**: accept **`subnet_id`** as **`projects/.../regions/.../subnetworks/...`** (cluster default) or full Compute API **self_link**, not only the latter.

### Changed

- **Documentation:** root **README.md** — documentation map (choose-your-path + section index), **Troubleshooting**, **Security notes (PoC hardening)**, **`configure-routing.sh` / `cudn_cidr` must match Terraform**, variable pointers to **`cluster_ilb_routing/variables.tf`** / **`terraform.tfvars.example`**, Terraform layout tree lists new READMEs, and **ILB / GKE / GCP support familiarity** (*ILB, mainstream GCP, and GKE (support familiarity)*); **ILB-vs-BGP.md** — Approach **A** GCP table and complexity row aligned with the reference ILB module, **ILB vs GKE vs BGP+NCC** section, comparison table row **Overlap with everyday GCP networking**; **wif_config/README.md** — keep **WIF** aligned with **`cluster_ilb_routing`** (`gcp_project_id`, `cluster_name`, `openshift_version`); **modules/osd-ilb-routing/README.md** — Git **`ref`** pinning, **`canIpForward`** links to repo **README** / **`cluster_ilb_routing/README`**; **Makefile** **`help`** — pointer to **`scripts/README.md`**.

- **`worker_subnet_to_cudn`** GCP firewall: allow **all protocols** from worker subnet to **`cudn_cidr`** (not only TCP + ICMP).

- Docs and **`configure-routing.sh`** verification hints: CUDN pods **`netshoot-cudn`** ( **`privileged: true`** ) and **`icanhazip-cudn`**; one **`oc wait`** for both before **`oc exec`** on netshoot.
- Docs: CUDN pod **`curl`** to the echo VM uses **`--connect-timeout 5`** / **`--max-time 15`**, notes **intermittent failures are under investigation**, and shows a **five-attempt** retry loop so checks usually succeed at least once.
- Echo client VM: **CentOS Stream 9** (`projects/centos-cloud/global/images/family/centos-stream-9`); bootstrap with **`startup-script`** metadata instead of **`user-data`**, because many GCP images do not ship or apply cloud-init.
- `wif_config/`: load **`osd-wif-config`** from GitHub (`git::https://github.com/rh-mobb/terraform-provider-osd-google.git//modules/osd-wif-config`) instead of a local path; align provider with **`~> 0.1.3`**; document and add **`make wif.*`** targets.
- `cluster_ilb_routing`: pin `rh-mobb/osd-google` to **`~> 0.1.3`** on the Terraform Registry (normal `terraform init`; no dev_overrides).
