# AWS-specific variable overrides and defaults.
# All variables are inherited from modules/vpn-server/variables.tf via the module call.

variable "project_name"          { default = "vpn-platform" }
variable "environment"           { default = "production" }
variable "region"                { default = "eu-west-1" }
variable "vm_size"               { default = "t3.small" }
variable "vpn_proxy_port"        { default = 8080 }
variable "ssh_public_key"        { sensitive = true }
variable "allowed_ingress_cidrs" { default = ["0.0.0.0/0"] }
variable "disk_size_gb"          { default = 20 }
variable "tags"                  { default = {} }
