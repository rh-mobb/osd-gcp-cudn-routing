# Optional echo-client VM for CUDN direct IP verification (icanhazip-clone).
# From a CUDN pod: curl (with connect/max timeouts) to http://<echo_vm_ip>:<port>/ returns the caller's IP.

check "echo_vm_requires_workers" {
  assert {
    condition     = !var.enable_echo_client_vm || length(var.router_instances) > 0
    error_message = "enable_echo_client_vm requires router_instances to derive zone when echo_client_vm_zone is null."
  }
}

locals {
  echo_vm_zone = var.echo_client_vm_zone != null ? var.echo_client_vm_zone : local.zones[0]
  echo_vm_tags = ["${var.cluster_name}-echo-client"]
}

resource "google_compute_instance" "echo_client" {
  count = var.enable_echo_client_vm ? 1 : 0

  project      = var.project_id
  name         = "${var.cluster_name}-echo-client"
  machine_type = var.echo_client_vm_machine_type
  zone         = local.echo_vm_zone
  tags         = local.echo_vm_tags

  boot_disk {
    initialize_params {
      image = "projects/centos-cloud/global/images/family/centos-stream-9"
    }
  }

  network_interface {
    subnetwork = var.subnet_id

    access_config {}
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      set -euxo pipefail
      dnf install -y podman || yum install -y podman
      systemctl stop firewalld 2>/dev/null || true
      systemctl disable firewalld 2>/dev/null || true
      podman rm -f icanhazip 2>/dev/null || true
      podman run -d --name icanhazip --restart=always -p ${var.echo_client_vm_port}:80 docker.io/thejordanprice/icanhazip-clone:latest
    EOT
  }

  allow_stopping_for_update = true
}

resource "google_compute_firewall" "echo_client_from_cudn" {
  count = var.enable_echo_client_vm ? 1 : 0

  project   = var.project_id
  name      = "${var.cluster_name}-echo-client-from-cudn"
  network   = var.vpc_id
  direction = "INGRESS"
  priority  = 900

  source_ranges = [var.cudn_cidr]
  target_tags   = local.echo_vm_tags

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "echo_client_ssh_public" {
  count = var.enable_echo_client_vm ? 1 : 0

  project     = var.project_id
  name        = "${var.cluster_name}-echo-client-ssh"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 100
  description = "Allow SSH to echo VM public IP (destination = instance internal IP /32)"

  source_ranges      = ["0.0.0.0/0"]
  destination_ranges = ["${google_compute_instance.echo_client[0].network_interface[0].network_ip}/32"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  depends_on = [google_compute_instance.echo_client]
}
