# OSD ILB Routing Module

Creates GCP Internal passthrough Network Load Balancer resources to
route CUDN traffic directly to OSD worker nodes, enabling non-NATted
pod/VM IP connectivity from the VPC.

## Usage

Set **`ref`** in the module source to a **Git tag** or **commit SHA** for reproducible installs (floating **`main`** is for development only).

```hcl
module "ilb_routing" {
  source = "git::https://github.com/rh-mobb/osd-gcp-cudn-routing.git//archive/modules/osd-ilb-routing?ref=main"

  project_id   = "my-project"
  region       = "us-central1"
  cluster_name = "my-cluster"
  vpc_id       = module.osd_vpc.vpc_id
  subnet_id    = "projects/my-project/regions/us-central1/subnetworks/my-cluster-worker-subnet"
  cudn_cidr    = "10.100.0.0/16"

  router_instances = [
    { self_link = "...", zone = "us-central1-a" },
  ]
}
```

Replace **`?ref=main`** with a **tag** (e.g. `?ref=v0.1.0`) or **SHA** before relying on the module in long-lived environments.

**Remote state:** for shared environments use a **GCS** backend — [docs/terraform-backend-gcs.md](../../../docs/terraform-backend-gcs.md), [**archive/cluster_ilb_routing/backend.tf.example**](../cluster_ilb_routing/backend.tf.example).

## Resources Created

- `google_compute_instance_group` -- One per zone, grouping worker instances
- `google_compute_health_check` -- TCP health check (default: kubelet port 10250; 10248 is localhost-only on OpenShift)
- `google_compute_region_backend_service` -- Internal passthrough NLB backend (backends use `CONNECTION` balancing; required for `INTERNAL` scheme)
- `google_compute_forwarding_rule` -- ILB frontend
- `google_compute_route` -- VPC route sending CUDN CIDR to the ILB
- `google_compute_firewall` -- **`${cluster_name}-worker-subnet-to-cudn`** — **`worker_subnet_to_cudn_firewall_mode`** (**`e2etest`**: ICMP + TCP/8080, **`all`**, **`none`**); optional **`routing_worker_target_tags`** (worker subnet → **`cudn_cidr`**)
- `google_compute_firewall` -- Allows GCP health check probes
- (Optional) `google_compute_instance` -- Echo VM running [icanhazip-clone](https://hub.docker.com/r/thejordanprice/icanhazip-clone) for CUDN-to-VM direct IP verification
- (Optional) `google_compute_firewall` -- Allows all protocols from CUDN CIDR to the echo VM
- (Optional) `google_compute_firewall` -- SSH (tcp:22) from IAP range `35.235.240.0/20` to the tagged echo VM (`gcloud compute ssh --tunnel-through-iap`)

## Optional Echo Client VM

When `enable_echo_client_vm = true`, the module creates a **CentOS Stream 9** VM (`centos-cloud` / `centos-stream-9`) on the worker subnet running [thejordanprice/icanhazip-clone](https://hub.docker.com/r/thejordanprice/icanhazip-clone) via **Podman**. Bootstrap uses GCE **`startup-script`** metadata (google-guest-agent) so **no cloud-init** is required. The script installs Podman, stops/disables `firewalld`, and runs the container. From a CUDN pod, `curl` with `--connect-timeout` / `--max-time` to `http://<echo_vm_ip>:8080/` returns the caller's IP as plain text—useful to verify direct pod connectivity vs SNAT behavior. **Intermittent `curl` failures are under investigation**; retry up to about five times with short pauses so a probe usually succeeds at least once.

**Firewall:** One ingress rule allows `protocol = "all"` from `cudn_cidr` to the tagged instance. Another allows SSH (tcp:22) from **`35.235.240.0/20`** (Google IAP for TCP forwarding) to the same tags so **`gcloud compute ssh --tunnel-through-iap`** reaches the VM’s internal address. No public IP on the VM.

**Variables:** `enable_echo_client_vm` (default `false`), `echo_client_vm_port` (8080), `echo_client_vm_zone` (null → first zone from `router_instances`), `echo_client_vm_machine_type` (`e2-micro`).

**Outputs:** `echo_client_vm_internal_ip`, `echo_client_vm_external_ip` (always `null`), `echo_client_http_url`, `echo_client_vm_zone`.

**NAT / egress:** Pulling the container image requires outbound internet. VMs without an external IP need Cloud NAT on the subnet (or Private Google Access with an Artifact Registry mirror). Otherwise `podman pull` may hang.

**After changing `startup-script`:** GCE may not re-run the script until the instance is **reset** or **recreated** (`gcloud compute instances reset …` or `terraform apply -replace='...echo_client[0]'`).

## Requirements

Worker instances must have `canIpForward=true` set at the GCE level
so they can accept and forward packets destined for pod IPs. This is
not managed by this module. See [archive/cluster_ilb_routing/README.md](https://github.com/rh-mobb/osd-gcp-cudn-routing/blob/main/archive/cluster_ilb_routing/README.md) (**`configure-routing.sh`**, verification, teardown) and the repository [README.md](https://github.com/rh-mobb/osd-gcp-cudn-routing/blob/main/README.md) for the overview.
