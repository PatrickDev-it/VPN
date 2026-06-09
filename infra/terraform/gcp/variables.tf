variable "project_name"          { default = "vpn-platform" }
variable "environment"           { default = "production" }
variable "region"                { default = "europe-west1" }
variable "vm_size"               { default = "e2-small" }
variable "vpn_proxy_port"        { default = 8080 }
variable "ssh_public_key"        { sensitive = true }
variable "allowed_ingress_cidrs" { default = ["0.0.0.0/0"] }
variable "disk_size_gb"          { default = 20 }
variable "tags"                  { default = {} }

variable "gcp_project" {
  description = "GCP project ID. Set via GOOGLE_PROJECT env var or -var flag."
  type        = string
}
