# Optional echo-client VM for CUDN direct IP verification (icanhazip-clone).
# From a CUDN pod: curl (with connect/max timeouts) to http://<echo_vm_ip>:<port>/ returns the caller's IP.

check "echo_vm_requires_zone" {
  assert {
    condition     = !var.enable_echo_client_vm || var.echo_client_vm_zone != null
    error_message = "enable_echo_client_vm requires echo_client_vm_zone to be set."
  }
}

locals {
  echo_vm_zone = var.echo_client_vm_zone
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
    # No external IP — SSH only via IAP: gcloud compute ssh --tunnel-through-iap
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

# IAP TCP forwarding range — https://cloud.google.com/iap/docs/using-tcp-forwarding#create_firewall_rule
resource "google_compute_firewall" "echo_client_ssh_iap" {
  count = var.enable_echo_client_vm ? 1 : 0

  project     = var.project_id
  name        = "${var.cluster_name}-echo-client-ssh"
  network     = var.vpc_id
  direction   = "INGRESS"
  priority    = 100
  description = "SSH to echo VM via IAP (gcloud compute ssh --tunnel-through-iap). Requires IAP API enabled and iap.tunnelInstances.accessViaIAP on the user."

  source_ranges = ["35.235.240.0/20"]
  target_tags   = local.echo_vm_tags

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  depends_on = [google_compute_instance.echo_client]
}

moved {
  from = google_compute_firewall.echo_client_ssh_public
  to   = google_compute_firewall.echo_client_ssh_iap
}
