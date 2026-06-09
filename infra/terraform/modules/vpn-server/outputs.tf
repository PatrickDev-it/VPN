# =============================================================================
# modules/vpn-server/outputs.tf
#
# Values returned to the caller after apply.
# Provider modules must populate these via their own output blocks.
# =============================================================================

output "public_ip" {
  description = "Public IPv4 address of the deployed VPN server."
  value       = var.region # placeholder — override in provider module
}

output "ssh_command" {
  description = "Ready-to-use SSH command for the deployed server."
  value       = "ssh root@<public_ip>"
}

output "proxy_endpoint" {
  description = "Proxy endpoint clients should configure."
  value       = "http://<public_ip>:${var.vpn_proxy_port}"
}
