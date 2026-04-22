# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`modules/osd-spoke-vpc`** — Added `google_compute_firewall.hub_to_spoke_return` rule (enabled via new `hub_egress_cidr` variable) allowing all traffic from the hub egress subnet back into the spoke VPC. Without this rule the hub NAT VMs could not route CUDN internet-egress return packets back to spoke worker nodes (GCP firewall silently dropped them), causing intermittent CUDN internet connectivity (~10% success rate due to GCP stateful firewall and 10-way Cloud Router ECMP). `cluster_bgp_routing/main.tf` now passes `module.hub.egress_subnet_cidr` to the spoke module automatically. Verified fix: MTR from both bridge and masquerade VMs shows 0% packet loss to icanhazip.com.
- **`modules/osd-hub-vpc`** — Added TCP MSS clamp (`tcp option maxseg size 1321-65535 → set 1320`) to the NAT VM startup script nftables ruleset. OVN-K's Geneve overlay reduces effective cluster MTU to ~1360 bytes (MSS 1320); without the clamp, remote servers send segments up to their own MSS (~1460) which are silently dropped inside the cluster. Previously applied ephemerally; now baked into the instance template so new VMs created by the MIG auto-healing or rolling update pick it up automatically.

### Changed

- **`cluster_bgp_routing/`** — **Hub + spoke VPCs** replace Git **`osd-vpc`**: [`modules/osd-hub-vpc`](modules/osd-hub-vpc/) (NAT MIG + internal NLB), [`modules/osd-spoke-vpc`](modules/osd-spoke-vpc/) (master/worker/PSC subnets), **VPC peering**, **`google_compute_route`** **`0.0.0.0/0` → hub NLB**. [`ARCHITECTURE.md`](ARCHITECTURE.md) updated.
- **Documentation** — [KNOWLEDGE.md](KNOWLEDGE.md): hub/spoke egress **verified**; GCP **Cloud NAT** vs **NIC-registered** sources; **secondary ranges / alias IPs** vs **BGP** overlap; **OSD on GCP network tags vs labels** / **tag-scoped routes** mitigated for greenfield; **`docs/nat-gateway.md`** moved to [`archive/docs/nat-gateway.md`](archive/docs/nat-gateway.md) (**superseded** header).

### Added

- **`make virt.e2e`** — [`scripts/e2e-virt-live-migration.sh`](scripts/e2e-virt-live-migration.sh): idempotent **`oc apply`** of **two** explicit **`VirtualMachine`s** on the **default pod network** (**`bridge: {}`** vs **`masquerade: {}`**) for console comparison, shared **cloud-init** **icanhazip-clone** on **8080**, **`netshoot-cudn`** ping/curl and three **VirtualMachineInstanceMigration** phases on the selected VM (**`VIRT_E2E_VM_NAME`**), **`--cleanup`** / **`VIRT_E2E_CLEANUP`**, optional **`--cleanup-include-test-pods`**.
- **Documentation** — [docs/bgp-manual-provision-and-teardown.md](docs/bgp-manual-provision-and-teardown.md): full **manual** BGP provision and teardown (`terraform`, `oc`, `gcloud`, repo paths only); optional pointer to the same ordering in [`scripts/bgp-apply.sh`](scripts/bgp-apply.sh), [`scripts/bgp-deploy-operator-incluster.sh`](scripts/bgp-deploy-operator-incluster.sh), and [`scripts/bgp-destroy.sh`](scripts/bgp-destroy.sh); linked from the [root README](README.md#quick-start--bgp).
- **`make virt.destroy-storage`** — [`scripts/destroy-openshift-virt-storage.sh`](scripts/destroy-openshift-virt-storage.sh) removes **`sp-balanced-storage`**, **`csi-gce-pd-vsc-images`**, restores **`standard-csi`** default, and deletes **`STORAGE_POOL_NAME`** GCP pools in **`virt_storage_zone`** when present, else each **`availability_zones`** entry (optional **`SKIP_GCP_POOLS`** / **`SKIP_CLUSTER_STORAGE`**).
- **`make virt.deploy`** — new target and [`scripts/deploy-openshift-virt.sh`](scripts/deploy-openshift-virt.sh): **Hyperdisk** pool + **StorageClass** + **VolumeSnapshotClass** (optional skip), then **CNV** via OLM (**`Subscription/hco-operatorhub`**, channel **`stable`**, [OCP 4.21 virtualization install](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/installing)), **HyperConverged** CR. Reads GCP project / region / zone from `cluster_bgp_routing/` Terraform outputs (**`virt_storage_zone`** when present). Env: `STORAGE_POOL_*`, `CNV_CHANNEL`, `CNV_SUBSCRIPTION_NAME`, `CNV_STARTING_CSV`, `SKIP_STORAGE`, `CNV_WAIT_TIMEOUT`. Storage: [gcp-storage-configuration-4.21](https://github.com/noamasu/docs/blob/main/gcp/gcp-storage-configuration-4.21.md).
- **`operator/` — CRD-based Kubernetes operator** — new Operator SDK-scaffolded operator with two cluster-scoped CRDs under `routing.osd.redhat.com/v1alpha1`:
  - **`BGPRoutingConfig`** (singleton, named `cluster`) — replaces the ConfigMap/env-var configuration surface; `.spec` holds all routing config, `.status` reports aggregated reconciliation state and conditions (`Ready`, `Degraded`, `Progressing`, `Suspended`).
  - **`BGPRouter`** (one per elected router node) — controller-managed status objects showing per-node GCP/FRR health with conditions (`CanIPForwardReady`, `NestedVirtReady`, `NCCSpokeJoined`, `BGPPeersConfigured`, `FRRConfigured`).
  - **Dual cleanup model:** finalizer-based cleanup on CR deletion (full teardown) and `spec.suspended` field for temporary disable-with-cleanup (preserves config for re-enablement).
  - **`observedGeneration`** tracking, printer columns, and standard Kubernetes conditions on both resources.
  - Labels and annotations use `routing.osd.redhat.com` prefix (renamed from `cudn.redhat.com`).
  - Proven domain logic from the legacy Go controller adapted for CRD-driven configuration.
- **Root Makefile** — `operator.build`, `operator.test`, `operator.generate`, `operator.manifests`, `operator.docker-build` targets.
- **`make create`** / **`make dev`** / **`make bgp.deploy-operator`** — [scripts/bgp-deploy-operator-incluster.sh](scripts/bgp-deploy-operator-incluster.sh): **`controller_gcp_iam`**, WIF Secret, CRDs, operator RBAC under **`operator/deploy/`**, **`BGPRoutingConfig`** from Terraform, ImageStream + BuildConfig + **`oc start-build`** from **`operator/`**, and **`deployment/bgp-routing-operator`**. Optional **`BGP_OPERATOR_PREBUILT_IMAGE`** skips the binary build.
- **CI workflow** — [`.github/workflows/publish-operator-image.yml`](.github/workflows/publish-operator-image.yml) builds and pushes the operator image to GHCR as `ghcr.io/<owner>/<repo>/bgp-routing-operator`.

### Fixed

- **`scripts/e2e-virt-live-migration.sh`** — **cloud-init** simplified: **`packages: [podman]`** and one-line **`runcmd`** entries (no nested **`bash -c`** / retry loops) so **`userData`** in live **VM** YAML is easy to inspect and diagnose.
- **`scripts/e2e-virt-live-migration.sh`** — **cloud-init** uses **`user` / `password` / `chpasswd.expire`** like **kubevirt/common-templates** (**`openshift/centos-stream9-server-small`**) so the OpenShift Virtualization **VM details** page shows **cloud-user** console credentials (not only **`chpasswd.list`**).
- **`scripts/e2e-virt-live-migration.sh`** — **`ensure_vm_running`** uses **`spec.runStrategy: Always`** when the template sets **`runStrategy`** (OCP 4.21+); avoids deprecated **`spec.running`**. **`CLUSTER_DIR/.virt-e2e/`** Ed25519 keypair + **`ssh_authorized_keys`**; **`console-password`** (**`VIRT_E2E_CONSOLE_PASSWORD`** or random) for console login; **Podman** **`--network host`** for **icanhazip**; **`**/.virt-e2e/`** gitignored; after **VMI Ready** print **console** + (if not primary UDN) **ssh** commands for debugging (primary UDN: **`virtctl ssh`** unsupported per product docs).
- **`scripts/destroy-openshift-virt-storage.sh`** — **GCP pool delete 400 (*storage pool is already being used by disk*)**: delete **DataImportCron** / **DataVolume** in **`openshift-virtualization-os-images`**, **VolumeSnapshots** cluster-wide, **PVCs** using **`sp-balanced-storage`**, wait for PVCs to clear (**`VIRT_DESTROY_WAIT_SEC`**, default **600**), then remove **VolumeSnapshotClass** / **StorageClass** / default **SC** restore; before **`gcloud compute storage-pools delete`**, delete **orphan zonal disks** still assigned to the pool (JSON **`storagePool`** match), with **one retry** after a failed pool delete.
- **`scripts/deploy-openshift-virt.sh`** — **GCP pool create:** **`--performance-provisioning-type=advanced`**, **`--provisioned-iops`**, **`--provisioned-throughput`** (fixes **400** *Pool provisioned IOPS must be specified*); default capacity **`10240GiB`** (10 TiB) per [Hyperdisk Balanced minimum](https://cloud.google.com/compute/docs/disks/storage-pools#pool-limits). **Preflight:** capacity / IOPS / throughput validation, **`oc apply --dry-run=client`** for StorageClass + CNV OLM + HyperConverged, **`curl`** HEAD on VolumeSnapshotClass URL (**`curl`** required unless **`SKIP_STORAGE=1`**). **OLM wait:** **`status.currentCSV`** + CSV list fallback and **`CNV_WAIT_DIAG_INTERVAL_SEC`** diagnostics (fixes hung wait on **`installedCSV`** only).

### Changed

- **`scripts/destroy-openshift-virt-storage.sh`** / **`make virt.destroy-storage`** — Deletes **all** **VirtualMachineInstanceMigration** and **VirtualMachine** resources cluster-wide and waits for **VirtualMachineInstance** teardown (same **`VIRT_DESTROY_WAIT_SEC`** window as PVC cleanup) **before** CDI, **VolumeSnapshot**, and **`sp-balanced-storage`** **PVC** removal so disks are not still attached to guests.
- **`scripts/e2e-virt-live-migration.sh`** — **Default** **`VIRT_E2E_SKIP_TESTS=1`**: creates the two VMs and prints **`virtctl console`** and **`virtctl ssh`** for both (no netshoot, migrations, or probes). **`--run-tests`** or **`VIRT_E2E_SKIP_TESTS=0`** restores the full e2e.
- **`scripts/e2e-virt-live-migration.sh`** — **VM provisioning** no longer uses **`oc process`** on **`openshift/centos-stream9-server-small`**. The script applies **two** **`kubevirt.io/v1` `VirtualMachine`s** via **`jq`** (**`DataVolumeTemplates`** + **`DataSource`** + **`cloudInitNoCloud`**, **`runStrategy: Always`**): one with **`bridge: {}`** and one with **`masquerade: {}`** on **`default`/`pod`**, for side-by-side **virtctl console** comparison. **`VIRT_E2E_VM_NAME`** / **`--vm-name`** picks which VM runs migrations and **`netshoot`** probes (must match **`VIRT_E2E_VM_NAME_BRIDGE`** or **`VIRT_E2E_VM_NAME_MASQ`**). **`vmi_probe_ip`** prefers **Terraform `cudn_cidr`** when choosing a guest IP, then falls back to any guest IPv4. **`--cleanup`** deletes by label **`routing.osd.redhat.com/virt-e2e=true`**. Env knobs include **`VIRT_E2E_BOOT_DATASOURCE_NAME`**, **`VIRT_E2E_BOOT_DATASOURCE_NAMESPACE`**, **`VIRT_E2E_BOOT_DISK_Gi`**, **`VIRT_E2E_BOOT_STORAGE_ACCESS_MODE`**, **`VIRT_E2E_VM_MEMORY`**, **`VIRT_E2E_VM_CPU`**. Removed **`--template-name`**, **`--template-ns`**, **`VIRT_E2E_TEMPLATE_*`**, **`VIRT_E2E_TEMPLATE_EXTRA_ARGS`**.
- **Documentation** — [ARCHITECTURE.md](ARCHITECTURE.md) and [scripts/README.md](scripts/README.md): **`virtctl console`** troubleshooting — **virtctl** vs **KubeVirt** version (**Help → Command line tools → virtctl**), and when versions already match: **WebSocket** path to the API vs the web UI (**`HTTP(S)_PROXY`** / **`NO_PROXY`**, **`apiservice`** / **`subresources.kubevirt.io`**, **`virtctl console vmi/…`**). [scripts/e2e-virt-live-migration.sh](scripts/e2e-virt-live-migration.sh) **`-h`**, runtime hints, and summary print **`vm/`** and **`vmi/`** console commands.
- **`cluster_bgp_routing`** — Terraform output **`virt_storage_zone`**: GCP zone for the zonal Hyperdisk pool used by **`make virt.deploy`** / **`make virt.destroy-storage`**. When **`create_baremetal_worker_pool`** is **true**, matches **`baremetal_availability_zones[0]`**; otherwise the first default worker zone. Virt scripts use this so the pool is not taken from **`availability_zones[0]`** alone when default workers are multi-AZ.
- **`scripts/deploy-openshift-virt.sh`** / **`scripts/destroy-openshift-virt-storage.sh`** — read **`virt_storage_zone`** first; destroy checks that zone only (single-AZ bare metal path). If the output is missing (Terraform not yet refreshed), behavior falls back to **`availability_zones[0]`** (deploy) or all **`availability_zones`** (destroy).
- **`scripts/bgp-apply.sh`** (**`make bgp.run`**, etc.) — **`oc login`** retries until success or **`OC_LOGIN_RETRY_MAX_SEC`** (default **600**), every **`OC_LOGIN_RETRY_INTERVAL_SEC`** (default **20**), when the admin credential from Terraform is not yet accepted after cluster apply. Documented in **`scripts/README.md`**.
- **`cluster_bgp_routing/`** — optional **second machine pool** (default **on**): **`create_baremetal_worker_pool`** provisions **`baremetal_worker_replicas`** (default **2**) **`baremetal_instance_type`** workers (default **`c3-standard-192-metal`**) in a **single AZ** via **`baremetal_availability_zones`** (default: first zone in the resolved default worker **`availability_zones`**). Set **`create_baremetal_worker_pool = false`** to omit the pool. Pool name defaults to **`baremetal`** (`baremetal_machine_pool_name`; **`worker`** / **`workers-*`** remain reserved by OCM).
- **`scripts/bgp-deploy-operator-incluster.sh`** (`make create` / `make dev` / `make bgp.deploy-operator`) — **`BGPRoutingConfig/cluster`** now sets **`spec.gce.enableNestedVirtualization: false`** so the operator does not enable GCE nested virtualization on router workers (aligned with OSD-GCP; enable explicitly in the CR if needed for lab topologies).
- **`scripts/deploy-openshift-virt.sh`** — **Storage first** (Hyperdisk pool, **StorageClass**, **`standard-csi`** default removal, **VolumeSnapshotClass**) per the [GCP virt storage guide](https://github.com/noamasu/docs/blob/main/gcp/gcp-storage-configuration-4.21.md), then **OLM** aligned with **OperatorHub** and [OpenShift Virtualization 4.21 install](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/installing): **`Subscription`** **`hco-operatorhub`**, channel **`stable`**, **`openshift-cnv`** label **`openshift.io/cluster-monitoring: "true"`**, optional **`CNV_STARTING_CSV`**, delete legacy **`Subscription/kubevirt-hyperconverged`** if present. **OperatorGroup:** skip creating **`kubevirt-hyperconverged-group`** if any **OperatorGroup** already exists in **`openshift-cnv`** (avoids **TooManyOperatorGroups** with Hub-created **`openshift-cnv-*`**); exit with a clear error if more than one **OperatorGroup** is present.
- **Legacy controllers archived** — `controller/go/` and `controller/python/` moved to `archive/controller/`; `scripts/bgp-deploy-controller-incluster.sh` and `scripts/terraform-controller-env-from-json.sh` moved to `archive/scripts/`. The operator under `operator/` is now the only active BGP reconciler.
- **`make create` / `make dev` / `make destroy`** — **`create`** and **`dev`** now deploy the **operator** (not the legacy controller); **`destroy`** runs **`bgp.destroy-operator`** (finalizer-based cleanup + IAM teardown) then **`bgp.teardown`**. **`make dev-operator`** is removed (redundant; **`dev`** is the operator path).
- **Makefile IAM targets renamed** — **`controller.gcp-iam.*`** targets renamed to **`iam.*`** (for example **`iam.init`**, **`iam.apply`**, **`iam.destroy`**); **`controller.gcp-credentials`** renamed to **`iam.credentials`**. The Terraform directory (`controller_gcp_iam/`) is unchanged.
- **All `controller.*` Makefile targets removed** — **`controller.run`**, **`controller.watch`**, **`controller.test`**, **`controller.cleanup`**, **`controller.build`**, **`controller.docker-build`**, **`controller.deploy-openshift`**, **`controller.venv`**, **`post-controller-deploy-msg`** are no longer available. Use the `operator.*` targets or `archive/controller/` for historical reference.
- **CI workflow renamed** — `.github/workflows/publish-controller-images.yml` replaced by `.github/workflows/publish-operator-image.yml`; builds only the operator image (legacy Go and Python controller images are no longer published).
- **Documentation updated** — all READMEs, `ARCHITECTURE.md`, `KNOWLEDGE.md`, `PRODUCTION.md`, and `AGENTS.md` rewritten to present the operator as the primary and only active reconciler.


- **`scripts/bgp-apply.sh`** (**`make bgp.run`**, **`make dev-operator`**, etc.) — when **`OC_LOGIN_EXTRA_ARGS`** is **unset**, it now defaults to **`--insecure-skip-tls-verify`**, so **`oc login`** does not wait up to **`OC_WAIT_API_TLS_MAX_SEC`** for a publicly trusted API certificate (self-signed / bootstrap API TLS is accepted immediately). To restore the previous behavior (poll **`/version`** until system CAs verify TLS, then **`oc login`** without that flag by default), **`export OC_LOGIN_EXTRA_ARGS=`** (empty string, but set). Documented in **`scripts/README.md`** and **`cluster_bgp_routing/README.md`**.

- **`make create`** / **`make dev`** — **`create`** now deploys the published Go controller image from **GHCR** (**`ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-controller-go:latest`** by default; override with **`CREATE_CONTROLLER_IMAGE`**) via **`BGP_CONTROLLER_PREBUILT_IMAGE`** in **`scripts/bgp-deploy-controller-incluster.sh`** (skips ImageStream, BuildConfig, and **`oc start-build`**). **`dev`** matches the former **`create`** flow (in-cluster binary build). **`bgp.deploy-controller`** honors **`BGP_CONTROLLER_PREBUILT_IMAGE`** when set manually. Neither **`create`** nor **`dev`** runs **`bgp.e2e`**; they print **`post-controller-deploy-msg`** (**`watch 'oc get nodes -l cudn.redhat.com/bgp-router='`** until every listed node is **Ready**, then **`make bgp.e2e`**).

### Fixed

- **`controller/go` / `controller/python` Makefiles (`run`, `watch`, `cleanup`)** — load cluster Terraform config via **`terraform output -json`** (**[`scripts/terraform-controller-env-from-json.sh`](scripts/terraform-controller-env-from-json.sh)**) instead of repeated **`terraform output -raw`**. When state has no outputs, Terraform can print a **“No outputs found”** warning to stdout and still exit **0**, which was captured into **`FRR_ASN`** and broke **`strconv.Atoi`** during **`make destroy`** / **`controller.cleanup`**. **`cleanup`** alone now **no-ops with a warning** when **`CLOUD_ROUTER_NAME`** is still empty after that (e.g. **`cluster_bgp_routing`** already destroyed) so **`make destroy`** can continue to **`bgp.teardown`**.

- **Controller `ClusterRole` (Go + Python `deploy/rbac.yaml`)** — grant **`update`** on **`nodes`** (not only **`patch`**): node label changes use **`client.Update`**, so without **`update`** the API rejects writes and the router label never appears (errors were previously ignored in **`SyncRouterLabels`**).

- **`controller/go/internal/reconciler/nodes.go`** — **`SyncRouterLabels`**, **`removeRouterLabelFromNonSelected`**, and **`RemoveAllRouterLabels`** return node **`Update`** errors instead of ignoring them.

- **FRRConfiguration neighbors (Go + Python)** — set **`disableMP: true`** again on Cloud Router neighbors. Omitting the field serializes as false; **OVN-K `RouteAdvertisements`** then stays **Not Accepted** with **`DisableMP==false not supported`**, so CUDN prefixes never merge into FRR and GCP sees **`numLearnedRoutes: 0`** for the CUDN CIDR.

- **Go controller logs** — each reconcile logs **start** / **completed** (counts and **`anyChange`**) from **`BGPReconciler`**; **`reconciler.Reconcile`** logs candidate selection, NCC / Cloud Router / FRR phases, and notable mutations. **`--once`** passes a logger **`IntoContext`** so the same phase logs appear locally.

- **`scripts/bgp-deploy-controller-incluster.sh`** / **`controller/go/Makefile`** / **`controller/python/Makefile`** — use **`--from-dir="${PWD}"`** (or **`$(CURDIR)`** in Make) instead of **`--from-dir=.`** so bash does not treat **`.`** as the **`source`** builtin and fail with **`.: --: invalid option`**.

- **BGP controllers (Go + Python)** — **`instances.update`** for **`advancedMachineFeatures.enableNestedVirtualization`** uses **`mostDisruptiveAllowedAction=RESTART`** (GCP returns **400** if **`REFRESH`** is used: required action **RESTART**). **`canIpForward`** still uses **`REFRESH`**.

- **`modules/osd-bgp-controller-iam`** — default **`custom_role_permissions`** adds **`compute.networks.get`** and **`compute.networks.updatePolicy`** (**`routers.get`** / **`instances.update`** can require them on some VPC topologies).

- **`controller/go/cmd/main.go`** — logs one **Application Default Credentials** line (**`jsonType`**, **`credentialSourceFile`**, impersonation flag) to confirm **WIF / `external_account`** in-cluster without printing secrets.

- **`controller/go/internal/reconciler/reconciler.go`** — **`EnsureCanIPForward`** / **`EnsureNestedVirtualization`** errors are returned instead of ignored.

- **Go controller `/readyz`** — readiness no longer calls **`GetRouterTopology`** on every probe (that could leave **`Deployment`** never **Ready** and **`oc rollout status`** over the progress deadline when WIF or GCP access is wrong). **`/readyz`** now uses **`healthz.Ping`** like **`/healthz`**; GCP is still used each reconcile.

- **Root `Makefile` help** — **`controller.build`** was documented as a container image build but only runs **`go build`** for the local binary; **`make controller.docker-build`** (delegates to **`controller/go` `docker-build`**) documents the image build path.

- **`scripts/bgp-apply.sh`** (**`make bgp.run`** / **`make create`** / **`make dev`**) — waits for the cluster API TLS certificate to verify against system CAs (probes **`/version`** with **`curl`**) before **`oc login`**, avoiding non-interactive hangs on the “unknown authority” prompt while OCM rolls out a public CA. Configurable via **`OC_WAIT_API_TLS_MAX_SEC`** and **`OC_WAIT_API_TLS_INTERVAL_SEC`**; skipped when **`OC_LOGIN_EXTRA_ARGS`** contains **`--insecure-skip-tls-verify`**. Documented in **`scripts/README.md`**.

- **`scripts/gcp-undelete-wif-custom-roles.sh`** — auto mode no longer relied on **`deleted: true`** in **`gcloud iam roles list --format=json`** (that field is not present in list output). Soft-deleted roles are detected by set-differencing role **`name`** lists with vs without **`--show-deleted`**. When that diff is empty but **`apply`** can still fail, the script prints **`gcloud`** list line counts and guidance for the **role_id tombstone** case (**`describe`** / **`undelete`** **`NOT_FOUND`**). **`scripts/README.md`** documents Terraform provider limits and manual **`gcloud`** checks.

### Changed

- **`make destroy`** / **`make bgp.destroy-controller`** / **`make bgp.teardown`** — print labeled phases and steps (Makefile **`echo`** plus clearer headers in **`scripts/bgp-destroy.sh`**) so teardown order is obvious in the log.

- **Root `Makefile`** — **`controller.gcp-iam.destroy`**, **`wif.destroy`**, and **`cluster.destroy`** now run **`terraform destroy -auto-approve`** (same non-interactive behavior as **`bgp.teardown`** / **`scripts/bgp-destroy.sh`**).

- **Router marker label (default `ROUTER_LABEL_KEY`)** — default is now **`cudn.redhat.com/bgp-router`** instead of **`node-role.kubernetes.io/bgp-router`** (OCM-friendly). Go + Python config defaults, **`deploy/configmap.yaml`**, and **`scripts/bgp-deploy-controller-incluster.sh`** updated.

- **Node annotations after GCP instance reconcile** — controllers set **`cudn.redhat.com/gcp-can-ip-forward=true`** after successful **`canIpForward`** ensure, and **`cudn.redhat.com/gcp-nested-virtualization=true`** when nested virt is enabled; nested annotation is cleared when nested virt is off. **`controller.cleanup`** / label removal strips both annotations with the router label.

- **CUDN e2e / test pods** — **`scripts/deploy-cudn-test-pods.sh`** and **`scripts/e2e-cudn-connectivity.sh`** no longer support **`--require-bgp-router`** (or related env vars); **`make bgp.e2e`** does not pass a router **nodeAffinity** because all workers are BGP peers in the reference design.

- **`scripts/bgp-deploy-controller-incluster.sh`**, **`controller/go/Makefile` `deploy-openshift`**, **`controller/python/Makefile` `deploy-openshift`** — after **`oc start-build … --follow`**, run **`oc rollout restart deployment/bgp-routing-controller`** so a new push to **`…:latest`** actually runs new pods; **`oc rollout status`** unchanged. **`controller/go/deploy/deployment.yaml`** and **`controller/python/deploy/deployment.yaml`** set **`imagePullPolicy: Always`** on the controller container.

- **`controller/go/Dockerfile`** — build stage uses **`registry.access.redhat.com/ubi9/ubi:latest`** with **`yum install go-toolset`** (current **Go 1.25** from UBI repos; avoids **`ubi9/go-toolset:9.5`** shipping older **Go 1.23**); runtime **`registry.access.redhat.com/ubi9/ubi-minimal:9.5`** with **`ca-certificates`**. Removed **`GOTOOLCHAIN=auto`**.

- **BGP controllers:** **`ENABLE_GCE_NESTED_VIRTUALIZATION`** is **on by default** when unset; set **`false`** to disable GCE nested virtualization on router VMs.

- **Makefile:** cluster-only **`cluster_bgp_routing/`** Terraform destroy is **`make cluster.destroy`** (renamed from **`make destroy`**). **`make destroy`** now runs **`bgp.destroy-controller`** then **`bgp.teardown`** (full quick-start teardown).

- **`scripts/deploy-cudn-test-pods.sh`** — **no longer deletes** test pods by default (avoids new CUDN IPs and BGP/GCP reconvergence on every e2e). Opt-in **`--recreate-test-pods`** or **`CUDN_TEST_PODS_RECREATE=1`** to delete **`netshoot-cudn`** / **`icanhazip-cudn`** before apply when the pod spec must be replaced (immutable fields). **`scripts/e2e-cudn-connectivity.sh`** adds **`--recreate-test-pods`** / **`CUDN_E2E_RECREATE_TEST_PODS`**.

- **`scripts/e2e-cudn-connectivity.sh`** — HTTP curl probes (**pod→VM** and **VM→pod**) use **more patient defaults** (12 attempts, 10s connect / 25s max per try, 3s sleep) and optional env **`CUDN_E2E_HTTP_CURL_ATTEMPTS`**, **`CUDN_E2E_HTTP_CONNECT_TIMEOUT`**, **`CUDN_E2E_HTTP_MAX_TIME`**, **`CUDN_E2E_HTTP_RETRY_SLEEP`** for flaky BGP/convergence. Connectivity steps **1–3** still always run; **Summary** + **exit 1** unchanged (except **`--allow-icmp-fail`**).

- **BGP controller — all candidate workers are BGP routers** — removed **`ROUTER_NODE_COUNT`** and subset selection; every node matching **`NODE_LABEL_KEY`** / **`NODE_LABEL_VALUE`** (excluding infra) gets **`canIpForward`**, NCC router-appliance membership, Cloud Router peers, and an **`FRRConfiguration`**. Use a custom label selector to limit which pools participate.

- **NCC spokes — multi-spoke + prefix config** — **`NCC_SPOKE_NAME`** / Terraform output **`ncc_spoke_name`** replaced by **`NCC_SPOKE_PREFIX`** / **`ncc_spoke_prefix`**. The controller creates spokes **`{prefix}-0`**, **`{prefix}-1`**, … with up to **8** instances per spoke (GCP limit) and deletes stale numbered spokes when workers are removed.

### Added

- **GitHub Actions — controller images on `main`** — [`.github/workflows/publish-controller-images.yml`](.github/workflows/publish-controller-images.yml) builds and pushes **`controller/go`** and **`controller/python`** to **GHCR** as **`ghcr.io/<owner>/<repo>/bgp-controller-go`** and **`…/bgp-controller-python`** (tags **`latest`**, branch, **`sha-<git>`**). Runs on pushes to **`main`** and **`workflow_dispatch`**.

- **[references/RFE-osd-google-wif-gcp-iam-lifecycle.md](references/RFE-osd-google-wif-gcp-iam-lifecycle.md)** — RFE for **terraform-provider-osd-google** / **osd-wif-gcp** (and related modules): WIF GCP **`google_project_iam_custom_role`** lifecycle, optional retention across teardown, split-stack pattern, and tombstone avoidance for repeated demos.

- **`scripts/gcp-undelete-wif-custom-roles.sh`** and **`make wif.undelete-soft-deleted-roles`** — default mode reads **`wif_config/`** Terraform (**`gcp_project_id`**, WIF **`role_prefix`**) and compares **`gcloud iam roles list`** with vs without **`--show-deleted`** to find soft-deleted roles (no manual role list). Optional **`--from-log`**, **`--terraform-dir` / `WIF_UNDELETE_TERRAFORM_DIR`**, **`--no-prefix-filter`**, **`--dry-run`**, **`--continue-on-error`**, or explicit **`PROJECT_ID ROLE_ID …`**. **`WIF_UNDELETE_ARGS`** on **`make`** is optional. Documented in **`scripts/README.md`**.

- **BGP controllers (Python and Go)** — **`ENABLE_GCE_NESTED_VIRTUALIZATION`** / **`enable_gce_nested_virtualization`**: reconciler sets **`advancedMachineFeatures.enableNestedVirtualization`** on each router worker’s GCE instance via **`compute.instances.update`** (same mechanism as **`canIpForward`**). **Defaults to on**; set **`false`** to skip. **Not supported on OSD-GCP**; for lab or unsupported topologies only.

- **`make bgp.destroy-controller`** — runs **`controller.cleanup`** then **`controller.gcp-iam.destroy`** (sequential; use before **`make bgp.teardown`** when you used the in-cluster controller). Quick start and teardown docs recommend this target instead of **`controller.cleanup`** alone for the scripted path.

- **`make create`** / **`make destroy`** — **`create`** runs **`bgp.run`**, **`bgp.deploy-controller`**, and **`bgp.e2e`** in order; **`destroy`** runs **`bgp.destroy-controller`** then **`bgp.teardown`**. Documented as the [README quick start](README.md#quick-start--bgp).

- **`controller/go/`** — BGP routing **controller** in **Go** using **controller-runtime** (Node watch, ConfigMap/env config, leader election, metrics `:8080`, health/readiness `:8081`, `--once` / `--cleanup`). OpenShift **Kustomize** manifests under **`controller/go/deploy/`**; **`scripts/bgp-deploy-controller-incluster.sh`** and root **`CONTROLLER_DIR`** now target this tree. Unit tests under **`internal/*`**. The **Python** controller remains under **`controller/python/`** for reference.

- **`KNOWLEDGE.md`** — documents verified facts and unverified assumptions about CUDN BGP routing across GCP and AWS, including the all-nodes-as-peers requirement discovered through cross-team collaboration and the AWS reference implementation (`references/rosa-bgp`).

- **`ARCHITECTURE.md`** — definitive architecture document covering the all-workers-as-BGP-peers design, GCP and OpenShift component breakdown, data plane flows (ingress/egress/intra-CUDN), control plane reconciliation, VM-specific considerations, and comparison with the AWS ROSA reference implementation.

### Changed

- **`KNOWLEDGE.md` and `ARCHITECTURE.md` consistency fixes** — corrected FRR daemon scope (runs on all nodes, not just BGP-peered nodes); clarified target vs current state for all-workers design; fixed ECMP description to note overlay forwarding is still needed for most flows; expanded egress data path to show OVN→host routing table transition; added `routingViaHost` and ECMP overlay forwarding as open questions; reframed bare-metal language as a support boundary, not a technical limitation.

- **`cluster_bgp_routing` default cluster:** **multi-AZ** default worker pool (**first three zones** in `gcp_region` via `google_compute_zones`), **`compute_nodes` = 6**, and explicit **`multi_az`** passed to **`osd-cluster`**. Replaced variable **`availability_zone`** with optional **`availability_zones`** (`null` = region default; one-element list = single-AZ). New Terraform output **`availability_zones`**; **`availability_zone`** remains as the **first** zone for backward compatibility.

- **RouteAdvertisements / fix-bgp-ra Phase 2:** Documented that **OVN-K validating admission rejects** **`spec.nodeSelector`** other than empty when **`advertisements`** includes **`PodNetwork`** (`If 'PodNetwork' is selected for advertisement, a 'nodeSelector' can't be specified as it needs to be advertised on all nodes`). [`cluster_bgp_routing/scripts/configure-routing.sh`](cluster_bgp_routing/scripts/configure-routing.sh) keeps **`nodeSelector: {}`** with an inline comment; [references/fix-bgp-ra.md](references/fix-bgp-ra.md) Phase 2 updated (**primary fix via RA nodeSelector is not applicable** on current OCP with this RA shape). Same rule is noted in [archive/cluster_ilb_routing/scripts/configure-routing.sh](archive/cluster_ilb_routing/scripts/configure-routing.sh).

- **Production docs:** Single root [PRODUCTION.md](PRODUCTION.md); former **`cluster_bgp_routing/PRODUCTION.md`** merged in and **removed**. Phased checklist: [cluster_bgp_routing/PRODUCTION-ROADMAP.md](cluster_bgp_routing/PRODUCTION-ROADMAP.md). Archived ILB: [archive/cluster_ilb_routing/PRODUCTION.md](archive/cluster_ilb_routing/PRODUCTION.md). Roadmap **§ 2A** uses **controller-first** worker lifecycle runbooks.

### Added

- **`make bgp.phase1-baseline`** / [`scripts/bgp-phase1-baseline.sh`](scripts/bgp-phase1-baseline.sh) — [references/fix-bgp-ra.md](references/fix-bgp-ra.md) **Phase 1** baseline (router nodes, **RouteAdvertisements** `nodeSelector`, **FRRConfiguration** list, **`debug-gcp-bgp.sh`**). Optional **`--e2e`**, **`--skip-gcp`**.

- **Reference plan:** [references/fix-bgp-ra.md](references/fix-bgp-ra.md) — CUDN ingress debugging (baseline, **Phase 2 RA `nodeSelector` blocked** with **`PodNetwork`**, forced placement e2e, all-worker BGP bisect).

- **`make bgp.deploy-controller`** / [`scripts/bgp-deploy-controller-incluster.sh`](scripts/bgp-deploy-controller-incluster.sh) — after **`make bgp.run`**, applies **`controller_gcp_iam/`**, WIF credential Secret, **ConfigMap** from **`cluster_bgp_routing` `terraform output`** (new output **`ncc_spoke_site_to_site_data_transfer`**), **`oc apply`** controller manifests (excluding checked-in **`deploy/configmap.yaml`** placeholders), binary **`BuildConfig`**, and rollout. Root [README § Quick start — BGP](README.md#quick-start--bgp) is three **`make`** steps end-to-end.

- **BGP controller GCP IAM (Terraform):** [`modules/osd-bgp-controller-iam/`](modules/osd-bgp-controller-iam/README.md) and root [`controller_gcp_iam/`](controller_gcp_iam/README.md) — custom role, dedicated service account, and **`roles/iam.workloadIdentityUser`** binding using **`data.osdgoogle_wif_config`** (same pool / provider IDs as **`osd-cluster`**). **`make controller.gcp-iam.*`** targets; **`make validate`** / **`make clean`** include this stack.
- **BGP controller WIF credential JSON:** [`scripts/bgp-controller-gcp-credentials.sh`](scripts/bgp-controller-gcp-credentials.sh) — runs **`gcloud iam workload-identity-pools create-cred-config`** from Terraform outputs; optional OpenShift Secret via **`--apply-secret`** or **`CONTROLLER_GCP_CRED_APPLY_SECRET=1`**. **`make controller.gcp-credentials`** from repo root.
- **BGP routing controller (Python / kopf):** [`controller/python/`](controller/python/README.md) — watches Nodes, selects a small set of **non-infra** workers for BGP (label **`node-role.kubernetes.io/bgp-router`**), reconciles **canIpForward**, **NCC spoke** (creates if missing), **Cloud Router BGP peers**, and **`FRRConfiguration`** CRs. Debounced event-driven + periodic drift loop. GCP auth via WIF credential config. Deployment manifests under `deploy/` (kustomize). Quick-win prototype for [PRODUCTION-ROADMAP.md § 4F](cluster_bgp_routing/PRODUCTION-ROADMAP.md).

- **Controller OpenShift deploy:** **`ImageStream`** + **Binary `BuildConfig`** (Docker strategy, **`triggers: []`**) so the image is built **in-cluster** and the **`Deployment`** pulls **`image-registry.openshift-image-registry.svc:5000/bgp-routing-system/bgp-routing-controller:latest`**. **`make deploy-openshift`** / **`make controller.deploy-openshift`** runs **`oc kustomize deploy/`** with WIF audience substitution, **`oc start-build … --from-dir=. --follow`**, and **`oc rollout status`**. Documented in [controller/python/README.md § Build and deploy](controller/python/README.md#build-and-deploy).

### Fixed

- **In-cluster controller NCC spoke create:** Custom IAM role now includes **`networkconnectivity.operations.get`**. The client library polls long-running operations after **`create_spoke`**; the controller SA lacked that permission and failed with **`403 Permission 'networkconnectivity.operations.get' denied`** while **`make controller.run`** (user ADC) succeeded. Re-apply **`controller_gcp_iam/`** (**`make controller.gcp-iam.apply`** or **`make bgp.deploy-controller`**) to update the role.

- **NCC spoke `update_spoke`:** Network Connectivity API rejects **`FieldMask`** path **`linked_router_appliance_instances`**; use **`linked_router_appliance_instances.instances`** ([`gcp.py`](controller/python/bgp_routing_controller/gcp.py)).

- **`iam.serviceAccounts.getAccessToken` / `PERMISSION_DENIED` on impersonation:** [`modules/osd-bgp-controller-iam`](modules/osd-bgp-controller-iam/main.tf) used **`principalSet://…/attribute.sub/…`** for **`roles/iam.workloadIdentityUser`**. Kubernetes workload identity requires **`principal://iam.googleapis.com/projects/…/workloadIdentityPools/POOL/subject/system:serviceaccount:NAMESPACE:KSA`** per [Google’s WIF + Kubernetes impersonation doc](https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes#service-account-impersonation). Terraform output renamed to **`workload_identity_principal_member`**. Re-run **`terraform apply`** in **`controller_gcp_iam/`** (or **`make bgp.deploy-controller`**) so the binding is replaced.

- **BGP controller WIF / GCP STS:** **`invalid_grant`** was caused by **`oidc.allowedAudiences`** on the OCM workload identity provider (often **`[\"openshift\"]`**) not matching the projected JWT **`aud`** (the **`//iam.googleapis.com/...`** form is **not** in that list). **`controller_gcp_iam`** now has **`wif_kubernetes_token_audience`** (default **`openshift`**) and output **`wif_kubernetes_token_audience`**; **`make bgp.deploy-controller`** / **`make deploy-openshift`** substitute that into **`deploy/deployment.yaml`**. **`create-cred-config`** / credential JSON still use the **`//iam.googleapis.com/...`** `audience` per [AIP-4117](https://google.aip.dev/auth/4117); **`scripts/bgp-controller-gcp-credentials.sh`** reads **`/var/run/secrets/tokens/gcp-wif/token`**. See [`controller_gcp_iam/README.md` § Troubleshooting](controller_gcp_iam/README.md#troubleshooting-invalid_grant--audience-mismatch).

- **`make bgp.deploy-controller`:** create namespace **`bgp-routing-system`** before the WIF credential **Secret** (avoids `namespaces "bgp-routing-system" not found`). **`controller_gcp_iam/credential-config.json`** added to **`.gitignore`**.

### Changed

- **ILB archived:** The ILB reference root (**`archive/cluster_ilb_routing/`**), reusable module (**`archive/modules/osd-ilb-routing/`**), comparison doc (**`archive/ILB-vs-BGP.md`**), and orchestration scripts (**`archive/scripts/ilb-apply.sh`**, **`ilb-destroy.sh`**) moved under **`archive/`**. The active repo layout and **`Makefile`** target BGP only (**`init`/`plan`/`apply`/`destroy`** use **`cluster_bgp_routing/`**; **`ilb.*`** targets removed). See [**archive/README.md**](archive/README.md).

- **`make controller.cleanup` / `--cleanup`:** Deletes the controller **`Deployment`** (**`bgp-routing-system`/`bgp-routing-controller`** by default) **first** if it exists, so the in-cluster operator does not race FRR/GCP teardown. Override with **`CONTROLLER_NAMESPACE`** and **`CONTROLLER_DEPLOYMENT_NAME`**.

- **BGP controller router nodes:** Selects a **bounded** set of workers (**2** if a single `topology.kubernetes.io/zone`, **3** if multiple zones; override with **`ROUTER_NODE_COUNT`**), **excludes infra** (`INFRA_EXCLUDE_LABEL_KEY`), **round-robins** across zones with preference for nodes already labeled **`ROUTER_LABEL_KEY`** (default **`node-role.kubernetes.io/bgp-router`**). The controller **patches** node labels and needs **`nodes` `patch`** in [`deploy/rbac.yaml`](controller/python/deploy/rbac.yaml). ConfigMap / **`make bgp.deploy-controller`** include **`ROUTER_NODE_COUNT`**, **`ROUTER_LABEL_KEY`**, **`INFRA_EXCLUDE_LABEL_KEY`**. Then **`make controller.cleanup`** removes **`ROUTER_LABEL_KEY`** from all nodes (after stopping the Deployment).

- **Makefile target naming** — use **`stack.action`** (dots). End-to-end orchestration: **`ilb.run`**, **`ilb.teardown`**, **`ilb.e2e`**, **`bgp.run`**, **`bgp.teardown`**, **`bgp.e2e`** (replacing **`ilb-apply`**, **`bgp-apply`**, …). Controller IAM: **`controller.gcp-iam.init`** / **`.plan`** / **`.apply`** / **`.destroy`** (replacing **`controller-gcp-iam.*`**). **`bgp.apply`** stays Terraform-only for **`cluster_bgp_routing/`** (no collision with **`bgp.run`**).

- **CUDN test pod icanhazip** ([`scripts/deploy-cudn-test-pods.sh`](scripts/deploy-cudn-test-pods.sh)): listens on **8080** via **`FLASK_APP=app.py`** and **`python -m flask run --port=$PORT`** (upstream image only exposes **`app.run(port=80)`**; Flask CLI ignores that block; matches echo VM **`echo_client_vm_port`** default). **[`scripts/e2e-cudn-connectivity.sh`](scripts/e2e-cudn-connectivity.sh)** curls **`http://<pod-ip>:8080/`** from the echo VM. **`worker_subnet_to_cudn_firewall_mode=e2etest`** in **`modules/osd-bgp-routing`** and **`modules/osd-ilb-routing`** now allows **TCP 8080** (was **80**) toward CUDN for that path.

- **BGP teardown:** **`make bgp.teardown`** / **`scripts/bgp-destroy.sh`** no longer run **`controller.cleanup`**. Run **`make controller.cleanup`** explicitly when the controller has reconciled (Cloud Router peers, NCC spoke, **`FRRConfiguration`**) so Terraform can remove instances. Removed **`make bgp.destroy`** — use **`terraform destroy`** from **`cluster_bgp_routing/`** for cluster-only expert teardown, or **`make bgp.teardown`** for cluster + WIF.

- **BGP controller default node selector:** **`NODE_LABEL_KEY`** default is now **`node-role.kubernetes.io/worker`** (was **`infra`**). Infra nodes typically do not run CUDN workloads, so OVN-K does not inject CUDN routes there and BGP sessions had nothing to advertise; workers match the reference stack’s per-node FRR behavior.

- **README:** BGP table and [§ Shared prerequisites](README.md#shared-prerequisites) now match the automations flow: single Terraform apply for static infra; **`configure-routing.sh`** only needs **`oc`**; **`make controller.*`** reads **`terraform output`** from **`cluster_bgp_routing/`**. Quick start states that controller reconciliation must run before **`bgp.e2e`**.

- **README:** BGP [quick start](README.md#quick-start--bgp) now includes **`make controller.venv`** / **`make controller.run`** (and pointers to **`controller.watch`** and in-cluster deploy) so the Python BGP controller is explicit after **`make bgp.run`**; Makefile summary lists **`controller.*`** targets.

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

- **`cluster_bgp_routing/PRODUCTION-ROADMAP.md`** -- phased, checkboxed roadmap for BGP production readiness: safety/correctness (Phase 1), operational foundations (Phase 2), multi-CUDN and observability (Phase 3), architecture and scale (Phase 4); includes e2e test checkpoint guidance between phases. Linked from root [PRODUCTION.md](PRODUCTION.md).

### Fixed

- **First `make bgp-apply` (single apply with `enable_bgp_routing=true`):** `data.google_compute_subnetwork.worker` in **`modules/osd-bgp-routing`** was read during plan before **`module.osd_vpc`** created the subnet, causing **subnetwork not found**. **`module.bgp_routing`** in **`cluster_bgp_routing/main.tf`** now has **`depends_on = [module.osd_vpc]`** so the data source reads after the subnet exists. The same **`depends_on`** is set on **`module.ilb_routing`** in **`cluster_ilb_routing/main.tf`** for consistency.

- **Controller `clear_peers` was a no-op:** `gcp.py` used `RoutersClient.patch()` with an empty `bgp_peers` list, but proto3 serialization omits empty repeated fields — the API silently ignored the change. Switched to `RoutersClient.update()` (PUT) which replaces the full resource and correctly clears the peers when running **`controller.cleanup`**.

- **`make controller.cleanup` / `controller.run` / `controller.watch`:** fixed `/bin/sh: output: command not found` — `controller/python` Makefile used `$(eval)` + `$(shell … terraform output …)` in recipes; on some environments Make still parsed `$(terraform …)` as Makefile syntax. Replaced with a single-line shell block and **backtick** command substitution for **`terraform output`**.

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
- **Production docs:** [PRODUCTION.md](PRODUCTION.md) is the **shared** overview (controller, cross-cutting gaps, ops). ILB-specific gaps: [cluster_ilb_routing/PRODUCTION.md](cluster_ilb_routing/PRODUCTION.md); BGP production notes live in root **PRODUCTION.md** (see current repo layout).

### Added

- **`modules/osd-bgp-routing`** — NCC hub, Router Appliance spoke, Cloud Router, per-worker BGP peers, firewalls (worker subnet → CUDN, BGP **tcp/179**), optional echo VM; outputs **`bgp_peer_matrix`** for **`configure-routing.sh`**.
- **`cluster_bgp_routing/`** — reference root module (VPC + OSD cluster + BGP module); **`enable_bgp_routing`** two-phase apply; BGP-specific **`scripts/`** (including **`discover-workers.sh`** with **`networkIP`**, **`configure-routing.sh`** with per-node **`FRRConfiguration`**).
- **`make bgp-apply`** / **`make bgp-destroy`** and **`scripts/bgp-apply.sh`** / **`scripts/bgp-destroy.sh`**; Makefile **`bgp.init`**, **`bgp.plan`**, **`bgp.apply`** for **`cluster_bgp_routing/`**; **`make validate`** includes the BGP stack.
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
