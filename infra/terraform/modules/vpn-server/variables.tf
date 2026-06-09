# =============================================================================
# modules/vpn-server/variables.tf
#
# Common input variables shared by all cloud provider implementations.
# Each provider module (aws/, gcp/, azure/) must pass these values.
# =============================================================================

variable "project_name" {
  description = "Short identifier used in resource names and tags."
  type        = string
  default     = "vpn-platform"
}

variable "environment" {
  description = "Deployment environment: production | staging | dev"
  type        = string
  default     = "production"
}

variable "region" {
  description = "Cloud region where the VPN server is deployed."
  type        = string
  # No default — must be set per provider.
}

variable "vm_size" {
  description = "Cloud-specific machine/instance type (e.g. t3.small, e2-small, Standard_B1s)."
  type        = string
  default     = "t3.small"
}

variable "vpn_proxy_port" {
  description = "TCP port exposed for proxy ingress (mitmproxy)."
  type        = number
  default     = 8080
}

variable "ssh_public_key" {
  description = "SSH public key content for operator access."
  type        = string
  sensitive   = true
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the VPN proxy port. Restrict to client IPs in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Additional key/value tags to attach to all resources."
  type        = map(string)
  default     = {}
}
