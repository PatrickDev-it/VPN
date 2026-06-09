# =============================================================================
# modules/vpn-server/main.tf
#
# Abstract module — defines the logical VPN server resource.
# This file contains NO provider-specific resources.
# All cloud-specific implementation lives in aws/, gcp/, azure/.
#
# To add a new cloud provider:
#   1. Create infra/terraform/<provider>/
#   2. Call this module with source = "../modules/vpn-server"
#   3. Implement the provider's VM, firewall, and key resources
#   4. Output public_ip, ssh_command, proxy_endpoint
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  # Uncomment and configure remote state for team use:
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "vpn-platform/terraform.tfstate"
  #   region = "eu-west-1"
  # }
}

# No resources defined at module level — provider modules instantiate them.
# This file serves as documentation anchor and version constraint.
