locals {
  hub_prefix_len = tonumber(split("/", var.hub_cidr)[1])
  egress_newbits = max(0, 24 - local.hub_prefix_len)
  egress_cidr    = cidrsubnet(var.hub_cidr, local.egress_newbits, 0)
  ilb_ip         = cidrhost(local.egress_cidr, var.nat_ilb_host_offset)
}

resource "google_compute_network" "hub" {
  project                 = var.project_id
  name                    = "${var.cluster_name}-hub-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "egress" {
  project       = var.project_id
  name          = "${var.cluster_name}-hub-egress"
  ip_cidr_range = local.egress_cidr
  region        = var.region
  network       = google_compute_network.hub.id

  private_ip_google_access = true
}

resource "google_compute_router" "hub" {
  project = var.project_id
  region  = var.region
  name    = "${var.cluster_name}-hub-cr"
  network = google_compute_network.hub.id

  bgp {
    asn = 64514
  }
}

# Cloud NAT for hub subnet only (NAT VM updates, health probes that originate on hub VMs).
resource "google_compute_router_nat" "hub" {
  project                            = var.project_id
  name                               = "${var.cluster_name}-hub-nat"
  router                             = google_compute_router.hub.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.egress.name
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_address" "nat_ilb" {
  project      = var.project_id
  name         = "${var.cluster_name}-nat-ilb-vip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.egress.id
  address_type = "INTERNAL"
  address      = local.ilb_ip
  # No purpose — SHARED_LOADBALANCER_VIP is incompatible with next_hop_ilb routes.
  # A plain INTERNAL address works for a passthrough NLB used as a route next hop.
}

resource "google_compute_instance_template" "nat_gw" {
  project      = var.project_id
  name_prefix  = "${var.cluster_name}-nat-gw-"
  machine_type = var.nat_vm_machine_type
  tags         = [var.nat_gw_tag]

  can_ip_forward = true

  disk {
    boot         = true
    auto_delete  = true
    source_image = "projects/centos-cloud/global/images/family/centos-stream-9"
    disk_size_gb = 20
  }

  network_interface {
    subnetwork = google_compute_subnetwork.egress.id
    access_config {}
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail

      HC_PORT=${var.health_check_port}

      cat > /etc/sysctl.d/90-nat-gw.conf <<'EOF'
      net.ipv4.ip_forward          = 1
      net.ipv4.conf.all.forwarding = 1
      EOF
      sysctl --system

      systemctl disable --now firewalld 2>/dev/null || true

      # CentOS Stream 9 nftables.service reads /etc/sysconfig/nftables.conf, not /etc/nftables.conf.
      # Write directly to the file the service loads and also apply immediately via nft -f.
      #
      # MSS clamp: the OVN-K Geneve overlay reduces effective MTU to ~1360 bytes inside the
      # cluster. Pods/VMs advertise MSS based on their interface MTU (1360 - 40 = 1320).
      # Without clamping, remote servers may send segments up to their own MSS (~1460) which
      # exceed the cluster path MTU and are silently dropped. We clamp any SYN/SYN-ACK with
      # MSS > 1320 down to 1320 to prevent this black-hole.
      cat > /etc/sysconfig/nftables.conf <<'NFT'
      flush ruleset
      table ip nat {
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          masquerade
        }
      }
      table inet filter {
        chain input   { type filter hook input   priority 0; policy accept; }
        chain forward { type filter hook forward priority 0; policy accept; }
        chain output  { type filter hook output  priority 0; policy accept; }
      }
      table ip mangle {
        chain FORWARD {
          type filter hook forward priority mangle; policy accept;
          tcp flags syn tcp option maxseg size 1321-65535 tcp option maxseg size set 1320
        }
      }
      NFT
      systemctl enable nftables
      nft -f /etc/sysconfig/nftables.conf

      # Network debug tools — installed once at first boot.
      #   tcpdump        packet capture on eth0/gif0 for egress/DNAT debugging
      #   conntrack-tools  inspect/flush conntrack table: conntrack -L -n -p tcp
      #   bind-utils     dig / nslookup / host for DNS verification
      #   iperf3         throughput and RTT measurement to/from spoke or internet
      #   nmap-ncat      nc for raw TCP/UDP port reachability probes
      #   net-tools      netstat -natp (familiar conntrack spot-check)
      #   ethtool        NIC ring / queue / offload stats (RSS, GRO inspection)
      dnf install -y \
        python3 \
        tcpdump \
        conntrack-tools \
        bind-utils \
        iperf3 \
        nmap-ncat \
        net-tools \
        ethtool \
        2>/dev/null || true

      # Minimal TCP listener for NLB health checks
      nohup python3 -m http.server $HC_PORT --bind 0.0.0.0 >/var/log/hc-http.log 2>&1 &
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }
}

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

  target_size                      = length(var.nat_vm_zones)
  distribution_policy_zones        = var.nat_vm_zones
  distribution_policy_target_shape = "EVEN"

  auto_healing_policies {
    health_check      = google_compute_health_check.nat_gw.id
    initial_delay_sec = var.healing_initial_delay_sec
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = length(var.nat_vm_zones)
    max_unavailable_fixed = 0
  }
}

resource "google_compute_region_backend_service" "nat_gw" {
  project               = var.project_id
  name                  = "${var.cluster_name}-nat-gw-bs"
  region                = var.region
  protocol              = "UNSPECIFIED"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_health_check.nat_gw.id]
  session_affinity      = "CLIENT_IP"

  backend {
    group          = google_compute_region_instance_group_manager.nat_gw.instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "nat_gw_ilb" {
  project               = var.project_id
  name                  = "${var.cluster_name}-nat-gw-ilb"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.nat_gw.id
  network               = google_compute_network.hub.id
  subnetwork            = google_compute_subnetwork.egress.id
  ip_address            = google_compute_address.nat_ilb.address
  all_ports             = true
  allow_global_access   = false
}

resource "google_compute_firewall" "nat_gw_allow_forwarded" {
  project   = var.project_id
  name      = "${var.cluster_name}-nat-gw-fwd"
  network   = google_compute_network.hub.id
  direction = "INGRESS"
  priority  = 900

  source_ranges = var.ingress_source_ranges
  target_tags   = [var.nat_gw_tag]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "nat_gw_iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  project   = var.project_id
  name      = "${var.cluster_name}-nat-gw-iap-ssh"
  network   = google_compute_network.hub.id
  direction = "INGRESS"
  priority  = 900

  # IAP TCP proxy source range — https://cloud.google.com/iap/docs/using-tcp-forwarding
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [var.nat_gw_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "nat_gw_health_check" {
  project   = var.project_id
  name      = "${var.cluster_name}-nat-gw-hc-fw"
  network   = google_compute_network.hub.id
  direction = "INGRESS"
  priority  = 900

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = [var.nat_gw_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.health_check_port)]
  }
}
