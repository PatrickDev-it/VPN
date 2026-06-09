# =============================================================================
# infra/terraform/aws/main.tf
#
# AWS deployment for the VPN Platform.
# Provisions: EC2 instance, Security Group, Key Pair.
#
# Prerequisites:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_DEFAULT_REGION=eu-west-1
#
# Usage:
#   cd infra/terraform/aws
#   terraform init
#   terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
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
# Key Pair
# ---------------------------------------------------------------------------
resource "aws_key_pair" "vpn" {
  key_name   = "${var.project_name}-${var.environment}"
  public_key = var.ssh_public_key

  tags = merge(var.tags, {
    Name        = "${var.project_name}-key"
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "vpn" {
  name        = "${var.project_name}-${var.environment}"
  description = "VPN Platform ingress rules"

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
    description = "SSH operator access"
  }

  # Proxy ingress
  ingress {
    from_port   = var.vpn_proxy_port
    to_port     = var.vpn_proxy_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
    description = "VPN proxy client access"
  }

  # All egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name        = "${var.project_name}-sg"
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# AMI — latest Ubuntu 22.04 LTS
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "vpn" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.vm_size
  key_name               = aws_key_pair.vpn.key_name
  vpc_security_group_ids = [aws_security_group.vpn.id]

  root_block_device {
    volume_size           = var.disk_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # Bootstrap: install git, clone repo, run install.sh
  user_data = templatefile("${path.module}/../../../deploy/cloud-init.sh.tpl", {
    repo_url    = "https://github.com/your-org/vpn-platform.git"
    repo_branch = "main"
    install_dir = "/opt/vpn-platform"
  })

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${var.environment}"
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "public_ip" {
  description = "Public IP of the VPN server."
  value       = aws_instance.vpn.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the server."
  value       = "ssh ubuntu@${aws_instance.vpn.public_ip}"
}

output "proxy_endpoint" {
  description = "Proxy endpoint for client configuration."
  value       = "http://${aws_instance.vpn.public_ip}:${var.vpn_proxy_port}"
}
