# =============================================================================
# infra/terraform/gcp/main.tf
#
# GCP deployment for the VPN Platform.
# Provisions: Compute Instance, Firewall Rules, SSH Keys.
#
# Prerequisites:
#   gcloud auth application-default login
#   export GOOGLE_PROJECT=your-gcp-project-id
#
# Usage:
#   cd infra/terraform/gcp
#   terraform init
#   terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
# =============================================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.region
}

module "vpn" {
  source = "../modules/vpn-server"

  project_name          = var.project_name
  environment           = var.environment
  region                = var.region
  vm_size               = var.vm_size
  vpn_proxy_port        = var.vpn_proxy_port
  ssh_public_key        = var.ssh_public_key
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  disk_size_gb          = var.disk_size_gb
  tags                  = var.tags
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "vpn_ingress" {
  name    = "${var.project_name}-${var.environment}-ingress"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22", tostring(var.vpn_proxy_port)]
  }

  source_ranges = var.allowed_ingress_cidrs
  target_tags   = ["${var.project_name}-${var.environment}"]
}

# ---------------------------------------------------------------------------
# Compute Instance
# ---------------------------------------------------------------------------
resource "google_compute_instance" "vpn" {
  name         = "${var.project_name}-${var.environment}"
  machine_type = var.vm_size
  zone         = "${var.region}-b"

  tags = ["${var.project_name}-${var.environment}"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    ssh-keys  = "ubuntu:${var.ssh_public_key}"
    user-data = templatefile("${path.module}/../../../deploy/cloud-init.sh.tpl", {
      repo_url    = "https://github.com/your-org/vpn-platform.git"
      repo_branch = "main"
      install_dir = "/opt/vpn-platform"
    })
  }

  labels = merge(var.tags, {
    environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "public_ip" {
  value = google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  value = "ssh ubuntu@${google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip}"
}

output "proxy_endpoint" {
  value = "http://${google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip}:${var.vpn_proxy_port}"
}
