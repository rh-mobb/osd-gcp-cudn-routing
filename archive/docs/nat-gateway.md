# NAT Gateway Implementation Plan

> **Superseded (greenfield hub/spoke):** Single-VPC NAT via ILB + tag-scoped routes was not implemented as written. **Internet egress** is delivered by **`modules/osd-hub-vpc`** + **`modules/osd-spoke-vpc`** + VPC peering + **`0.0.0.0/0` → hub NLB** (see [ARCHITECTURE.md](../../ARCHITECTURE.md)). This document remains useful background on **Cloud NIC registration**, **OVN-K EgressIP**, and **nftables MASQUERADE** patterns.

## Background: Why Cloud NAT Cannot Handle CUDN Egress

### What OVN-K intends to do

OVN-Kubernetes is aware of the GCP egress problem.
Its solution for CUDN internet egress is `EgressIP`: a controller that programs OVS flows on each node to intercept CUDN-sourced packets and SNAT them to a floating IP in the worker subnet (e.g. `10.0.32.200`) before the packet reaches the GCP NIC.
`10.0.32.200` is a valid GCP-registered IP, so Cloud NAT would handle it correctly.

### What actually happens (the bug)

OVN-K's EgressIP implementation is broken for Layer2 primary UDN when the CUDN uses a centralized Gateway Router (`l3gateway`).
The SNAT OVS flows are only generated on the one node where the CUDN GR is pinned.
On all other nodes, the EgressIP lflow produces no OVS translation because the transit switch outport has no chassis binding.

The result, confirmed live against this cluster, is two competing OVS flows on `br-ex`:

```text
# Fires on GR node only (priority=105) — SNAT working correctly:
priority=105, pkt_mark=0xc350, nw_src=10.100.0.0/16
  → ct(commit,zone=64000,nat(src=10.0.32.200)),output:1

# Fires on every other node (priority=104) — bypass, exits NIC with raw CUDN IP:
priority=104, nw_src=10.100.0.0/16, in_port=3
  → output:1   # src=10.100.0.x, no SNAT
```

On 4 out of 5 BGP-enabled worker nodes, CUDN packets exit the physical NIC with `src=10.100.0.x`.

### Why Cloud NAT then drops those packets

GCP Cloud NAT is a **host-NIC-aware** service.
When a packet leaves a GCP VM, Cloud NAT checks whether the source IP belongs to a range explicitly registered against that VM's network interface.
`10.100.0.x` is not a GCP-assigned NIC IP and is not a secondary range of the worker subnet.
Cloud NAT finds no matching registration and **silently drops the packet**.
This occurs regardless of the Cloud NAT configuration (`ALL_IP_RANGES`, `ALL_SUBNETWORKS_ALL_IP_RANGES`, or any subnetwork variant) because the check is against GCP's NIC registration, not the Cloud NAT policy.

The OVN-K bug is tracked separately and should be filed upstream (see [egress-ip.md](../references/egress-ip.md)).
This module works around it entirely at the GCP infrastructure level without any dependency on OVN-K's SNAT behaviour.

### Enterprise Framing

For organisations that require centralised egress control — consistent source IPs for allowlisting, auditable outbound traffic, a single point to apply egress firewall policy — Cloud NAT is often not sufficient regardless of CUDN.
Running dedicated NAT gateway instances inside the VPC is the standard pattern for secure enterprise GCP deployments, equivalent to an AWS NAT Gateway pair or an on-premises perimeter firewall.
This implementation adopts that pattern: all VPC egress (cluster pods, CUDN pods, system traffic) flows through a small pool of gateway VMs.
The VMs perform `MASQUERADE` at the Linux kernel level before GCP sees the packet, so any source IP is valid — overlay networks, CUDN ranges, and standard pod CIDRs all work identically.

---

## Architecture

```
  Cluster VMs (masters, workers)            NAT Gateway VMs
  [tag: nat-client]                         [tag: nat-gw, 1 per AZ]
       │                                         │
       │ 0.0.0.0/0 custom VPC route              │  nftables MASQUERADE
       │ priority 800, tag=nat-client             │  → external IP (ephemeral)
       ▼                                         │
  ┌─────────────────────────┐                    │
  │  Internal Passthrough   │────────────────────┘
  │  NLB  (ILB VIP)         │  SESSION_AFFINITY=CLIENT_IP
  │  one regional forwarding │  backend = regional MIG
  │  rule, all AZs          │  auto-heals in <60 s per zone
  └─────────────────────────┘
       │
       ▼
   Internet  (via each NAT VM's ephemeral external IP)
```

**One NAT VM per availability zone**, managed by a regional Managed Instance Group (MIG).
The MIG auto-heals: if a VM fails its health check it is recreated in the same zone within ~60 seconds.
An Internal Passthrough NLB in front of the MIG routes traffic with `SESSION_AFFINITY=CLIENT_IP` so established connections stick to one VM and conntrack is preserved.

The NAT VMs are excluded from the custom 0.0.0.0/0 route by network tag — they reach the internet directly via their own ephemeral external IPs using GCP's default internet gateway.
No routing loop is possible.

---

## New Terraform Module: `modules/osd-nat-gateway/`

Create the following file layout.
The module is gated by `count = var.enable_nat_gateway ? 1 : 0` in the caller.

```
modules/osd-nat-gateway/
├── versions.tf          # provider requirements
├── variables.tf         # all inputs
├── main.tf              # MIG, ILB, health check, route
├── firewall.tf          # ingress + health-check firewall rules
└── outputs.tf           # ilb_ip, mig_name, instance_tag
```

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
    }
  }
}
```

### `variables.tf` (key inputs)

```hcl
variable "project_id"   { type = string }
variable "region"       { type = string }
variable "cluster_name" { type = string }
variable "vpc_id"       { type = string }
variable "subnet_id"    { type = string }

variable "zones" {
  type        = list(string)
  description = "AZs to place one NAT VM in each. Typically the same as cluster_availability_zones."
}

variable "machine_type" {
  type    = string
  default = "e2-medium"
}

variable "nat_gw_tag" {
  type    = string
  default = "nat-gw"
  description = "Network tag applied to NAT VMs. These VMs must NOT carry nat_client_tag."
}

variable "nat_client_tag" {
  type        = string
  default     = "nat-client"
  description = "Network tag on cluster VMs that should use the NAT route."
}

variable "route_priority" {
  type    = number
  default = 800
  description = "Priority for the 0.0.0.0/0 custom route. Lower wins; default GCP internet gateway is 1000."
}

variable "health_check_port" {
  type    = number
  default = 22
  description = "TCP port for MIG auto-healing health check."
}

variable "healing_initial_delay_sec" {
  type    = number
  default = 180
  description = "Seconds to wait before starting health checks on a new instance."
}

variable "ilb_host_offset" {
  type    = number
  default = 240
  description = "Host index in the worker subnet CIDR to reserve as the ILB VIP (e.g. 240 → 10.0.32.240)."
}
```

### `main.tf` — core resources

```hcl
data "google_compute_subnetwork" "worker" {
  self_link = var.subnet_id
}

locals {
  ilb_ip = cidrhost(data.google_compute_subnetwork.worker.ip_cidr_range, var.ilb_host_offset)
}

# ── Instance template ────────────────────────────────────────────────────────

resource "google_compute_instance_template" "nat_gw" {
  project      = var.project_id
  name_prefix  = "${var.cluster_name}-nat-gw-"
  machine_type = var.machine_type
  tags         = [var.nat_gw_tag]

  can_ip_forward = true

  disk {
    boot         = true
    auto_delete  = true
    source_image = "projects/centos-cloud/global/images/family/centos-stream-9"
    disk_size_gb = 20
  }

  network_interface {
    subnetwork = var.subnet_id
    access_config {}   # ephemeral external IP — NAT VMs reach internet directly
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail

      # Persistent IP forwarding
      cat > /etc/sysctl.d/90-nat-gw.conf <<'EOF'
      net.ipv4.ip_forward          = 1
      net.ipv4.conf.all.forwarding = 1
      EOF
      sysctl --system

      # Disable firewalld; manage rules with nftables directly
      systemctl disable --now firewalld 2>/dev/null || true

      # Write nftables config: MASQUERADE all forwarded traffic leaving ens4
      cat > /etc/nftables.conf <<'EOF'
      #!/usr/sbin/nft -f
      flush ruleset
      table ip nat {
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          oifname "ens4" masquerade
        }
      }
      table inet filter {
        chain input   { type filter hook input   priority 0; policy accept; }
        chain forward { type filter hook forward priority 0; policy accept; }
        chain output  { type filter hook output  priority 0; policy accept; }
      }
      EOF
      systemctl enable --now nftables
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Regional MIG: one instance per zone ──────────────────────────────────────

resource "google_compute_health_check" "nat_gw" {
  project = var.project_id
  name    = "${var.cluster_name}-nat-gw-hc"

  tcp_health_check {
    port = var.health_check_port
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_region_instance_group_manager" "nat_gw" {
  project            = var.project_id
  name               = "${var.cluster_name}-nat-gw-mig"
  region             = var.region
  base_instance_name = "${var.cluster_name}-nat-gw"

  version {
    instance_template = google_compute_instance_template.nat_gw.id
  }

  # One VM per AZ — total = len(zones)
  target_size = length(var.zones)

  distribution_policy_zones            = var.zones
  distribution_policy_target_shape     = "EVEN"

  auto_healing_policies {
    health_check      = google_compute_health_check.nat_gw.id
    initial_delay_sec = var.healing_initial_delay_sec
  }

  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = length(var.zones)
    max_unavailable_fixed        = 0
  }
}

# ── Internal Passthrough NLB ──────────────────────────────────────────────────

resource "google_compute_region_backend_service" "nat_gw" {
  project               = var.project_id
  name                  = "${var.cluster_name}-nat-gw-bs"
  region                = var.region
  protocol              = "UNSPECIFIED"   # passthrough
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_health_check.nat_gw.id]
  session_affinity      = "CLIENT_IP"

  backend {
    group = google_compute_region_instance_group_manager.nat_gw.instance_group
  }
}

resource "google_compute_forwarding_rule" "nat_gw_ilb" {
  project               = var.project_id
  name                  = "${var.cluster_name}-nat-gw-ilb"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.nat_gw.id
  network               = var.vpc_id
  subnetwork            = var.subnet_id
  ip_address            = local.ilb_ip
  all_ports             = true
  allow_global_access   = false   # same-region only; cluster VMs are in the same region
}

# ── Custom default route → ILB (scoped to nat-client tagged VMs) ─────────────

resource "google_compute_route" "default_via_nat" {
  project          = var.project_id
  name             = "${var.cluster_name}-default-via-nat"
  network          = var.vpc_id
  dest_range       = "0.0.0.0/0"
  priority         = var.route_priority
  next_hop_ilb     = google_compute_forwarding_rule.nat_gw_ilb.id
  tags             = [var.nat_client_tag]   # only VMs with this tag use this route
}
```

### `firewall.tf`

```hcl
# Allow all forwarded traffic to reach the NAT VMs (from the entire VPC CIDR).
resource "google_compute_firewall" "nat_gw_allow_forwarded" {
  project   = var.project_id
  name      = "${var.cluster_name}-nat-gw-fwd"
  network   = var.vpc_id
  direction = "INGRESS"
  priority  = 900

  source_ranges = [data.google_compute_subnetwork.worker.ip_cidr_range]
  target_tags   = [var.nat_gw_tag]

  allow { protocol = "all" }
}

# GCP health check probe ranges (required for MIG auto-healing)
resource "google_compute_firewall" "nat_gw_health_check" {
  project   = var.project_id
  name      = "${var.cluster_name}-nat-gw-hc"
  network   = var.vpc_id
  direction = "INGRESS"
  priority  = 900

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = [var.nat_gw_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.health_check_port)]
  }
}
```

### `outputs.tf`

```hcl
output "ilb_ip"         { value = local.ilb_ip }
output "mig_name"       { value = google_compute_region_instance_group_manager.nat_gw.name }
output "nat_gw_tag"     { value = var.nat_gw_tag }
output "nat_client_tag" { value = var.nat_client_tag }
```

---

## Changes to `cluster_bgp_routing/main.tf`

Add the module call after `module.osd_vpc`:

```hcl
module "nat_gateway" {
  source = "../modules/osd-nat-gateway"
  count  = var.enable_nat_gateway ? 1 : 0

  depends_on = [module.osd_vpc]

  project_id     = var.gcp_project_id
  region         = var.gcp_region
  cluster_name   = var.cluster_name
  vpc_id         = module.osd_vpc.vpc_id
  subnet_id      = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${module.osd_vpc.compute_subnet}"
  zones          = local.cluster_availability_zones
  machine_type   = var.nat_gw_machine_type
  nat_client_tag = var.nat_client_tag
  ilb_host_offset = var.nat_ilb_host_offset
}
```

New variables to add to `cluster_bgp_routing/variables.tf`:

```hcl
variable "enable_nat_gateway" {
  type    = bool
  default = false
  description = "Deploy in-VPC NAT gateway VMs (one per AZ) replacing Cloud NAT."
}

variable "nat_gw_machine_type" {
  type    = string
  default = "e2-medium"
  description = "Machine type for NAT gateway VMs."
}

variable "nat_client_tag" {
  type    = string
  default = "nat-client"
  description = "Network tag that must be present on all cluster VMs (masters + workers) to use the NAT gateway route."
}

variable "nat_ilb_host_offset" {
  type    = number
  default = 240
  description = "Host offset in the worker subnet CIDR for the ILB VIP (e.g. 240 → cidrhost(subnet, 240))."
}
```

---

## Changes to the Upstream `osd-vpc` Module

The `osd-vpc` module (`rh-mobb/terraform-provider-osd-google`) currently creates two Cloud NAT resources unconditionally.
Add an `enable_cloud_nat` variable (default `true`) to gate them:

```hcl
# In modules/osd-vpc/variables.tf (upstream PR):
variable "enable_cloud_nat" {
  type    = bool
  default = true
  description = "Create Cloud NAT for master and worker subnets. Set false when using in-VPC NAT gateway VMs."
}

# In modules/osd-vpc/main.tf, wrap both router_nat resources:
resource "google_compute_router_nat" "nat_master" {
  count = var.enable_cloud_nat ? 1 : 0
  ...
}

resource "google_compute_router_nat" "nat_worker" {
  count = var.enable_cloud_nat ? 1 : 0
  ...
}
```

Until the upstream PR merges, use a Terraform `removed` block in `cluster_bgp_routing/main.tf` to destroy the existing Cloud NAT resources without modifying the module source:

```hcl
# Add to cluster_bgp_routing/main.tf when enable_nat_gateway = true:
removed {
  from = module.osd_vpc.google_compute_router_nat.nat_master
  lifecycle { destroy = true }
}
removed {
  from = module.osd_vpc.google_compute_router_nat.nat_worker
  lifecycle { destroy = true }
}
```

---

## Network Tag Wiring

The `nat-client` tag must be on every VM whose traffic should flow through the NAT gateway.
In an OSD CCS cluster the instance templates are under customer control.

| Resource | How to apply `nat-client` tag |
|----------|-------------------------------|
| Default worker pool | `google_compute_instance_template` in the `osd-cluster` module (upstream PR), or via OCM MachinePool labels mapped to GCP tags |
| Bare metal worker pool | Same — add to the machine pool's instance template |
| Master nodes | Tag applied via `google_compute_instance` or `google_compute_instance_template` in `osd-cluster` module |
| NAT VMs | Carry `nat-gw` only — explicitly excluded from the custom route |

Until the upstream module supports tag injection, tags can be applied post-deploy via:

```bash
gcloud compute instances add-tags INSTANCE_NAME \
  --tags=nat-client --zone=ZONE --project=PROJECT
```

This is idempotent and can be scripted across all worker nodes.

---

## Data Flow Verification

After deployment, verify end-to-end from a CUDN pod on each node:

```bash
# From each netshoot probe pod — should return a NAT VM external IP, not 10.100.x.x
oc exec -n cudn1 <pod> -- curl -s --max-time 10 ifconfig.me

# Confirm the ILB VIP is reachable
oc exec -n cudn1 <pod> -- ping -c 3 <ilb_ip>

# Check MIG health in GCP
gcloud compute backend-services get-health <cluster>-nat-gw-bs \
  --region=<region> --project=<project>
```

---

## Implementation Checklist

### Phase 1 — Add NAT gateway alongside Cloud NAT

- [ ] Create `modules/osd-nat-gateway/` with `versions.tf`, `variables.tf`, `main.tf`, `firewall.tf`, `outputs.tf`
- [ ] Add `enable_nat_gateway`, `nat_gw_machine_type`, `nat_client_tag`, `nat_ilb_host_offset` variables to `cluster_bgp_routing/variables.tf`
- [ ] Add `module "nat_gateway"` call to `cluster_bgp_routing/main.tf`
- [ ] Add new variables to `cluster_bgp_routing/terraform.tfvars.example`
- [ ] Run `terraform plan -var enable_nat_gateway=true` — verify ~10 resources to create, 0 to destroy
- [ ] Apply — NAT VMs come up, ILB becomes healthy, custom route is active
- [ ] Tag cluster worker and master VMs with `nat-client`
- [ ] Verify all pods can egress: `curl ifconfig.me` returns NAT VM external IP
- [ ] Verify CUDN pods on every node work (previously broken on non-GR nodes)

### Phase 2 — Remove Cloud NAT

- [ ] Add `removed {}` blocks for `nat_master` and `nat_worker` to `main.tf`
- [ ] Run `terraform plan` — verify only Cloud NAT resources are destroyed, nothing else
- [ ] Apply — Cloud NAT removed; all egress now goes through NAT VMs
- [ ] Re-run verification from Phase 1
- [ ] Open upstream PR to `rh-mobb/terraform-provider-osd-google` adding `enable_cloud_nat` variable

### Phase 3 — Production hardening (follow-up)

- [ ] Promote NAT VM external IPs to static addresses if downstream allowlisting is required
- [ ] Add Cloud Monitoring alert: MIG target size != healthy backends
- [ ] Add Cloud Monitoring alert: NAT VM CPU > 80% (scale up machine type or add VMs)
- [ ] Consider `e2-standard-4` for higher-throughput clusters (e2-medium caps at ~4 Gbps)
- [ ] File upstream OVN-K bug: EgressIP missing flows on non-GR nodes for Layer2 UDN

---

## Rollback

The custom route is applied at a lower priority (800) than the default GCP internet gateway (1000).
To instantly revert traffic to Cloud NAT (if Cloud NAT still exists), delete the custom route:

```bash
gcloud compute routes delete <cluster>-default-via-nat --project=<project>
```

To revert via Terraform:

```bash
terraform apply -var enable_nat_gateway=false
# and remove the `removed {}` blocks if Phase 2 has not run
```

---

## Trade-offs

| | Cloud NAT | NAT Gateway VMs |
|---|---|---|
| CUDN egress | Broken | Works |
| Self-healing | Built-in (managed service) | Regional MIG, ~60 s per zone |
| Throughput | Effectively unlimited | ~4 Gbps per VM (e2-medium) |
| Egress IPs | GCP-managed pool (unstable) | Per-VM ephemeral (or static) |
| Connection on failover | N/A | Reconnects when MIG heals |
| Egress visibility | Cloud NAT logs | VM-level access logs / syslog |
| Cost | Per-GB + IP charges | VM compute + external IP charges |
| Operational model | Zero-touch | MIG-managed; OS patching via rolling replace |
