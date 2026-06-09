# =============================================================================
# infra/terraform/azure/main.tf
#
# Azure deployment for the VPN Platform.
# Provisions: Resource Group, VNet, NSG, Public IP, NIC, Linux VM.
#
# Prerequisites:
#   az login
#   az account set --subscription <subscription-id>
#
# Usage:
#   cd infra/terraform/azure
#   terraform init
#   terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
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

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "vpn" {
  name     = local.name_prefix
  location = var.region
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "vpn" {
  name                = "${local.name_prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.vpn.location
  resource_group_name = azurerm_resource_group.vpn.name
}

resource "azurerm_subnet" "vpn" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.vpn.name
  virtual_network_name = azurerm_virtual_network.vpn.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "vpn" {
  name                = "${local.name_prefix}-ip"
  location            = azurerm_resource_group.vpn.location
  resource_group_name = azurerm_resource_group.vpn.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ---------------------------------------------------------------------------
# Network Security Group
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "vpn" {
  name                = "${local.name_prefix}-nsg"
  location            = azurerm_resource_group.vpn.location
  resource_group_name = azurerm_resource_group.vpn.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "VPN-Proxy"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.vpn_proxy_port)
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "vpn" {
  name                = "${local.name_prefix}-nic"
  location            = azurerm_resource_group.vpn.location
  resource_group_name = azurerm_resource_group.vpn.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vpn.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vpn.id
  }
}

resource "azurerm_network_interface_security_group_association" "vpn" {
  network_interface_id      = azurerm_network_interface.vpn.id
  network_security_group_id = azurerm_network_security_group.vpn.id
}

# ---------------------------------------------------------------------------
# Linux VM
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "vpn" {
  name                = local.name_prefix
  resource_group_name = azurerm_resource_group.vpn.name
  location            = azurerm_resource_group.vpn.location
  size                = var.vm_size

  admin_username = "ubuntu"
  network_interface_ids = [azurerm_network_interface.vpn.id]

  admin_ssh_key {
    username   = "ubuntu"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/../../../deploy/cloud-init.sh.tpl", {
    repo_url    = "https://github.com/your-org/vpn-platform.git"
    repo_branch = "main"
    install_dir = "/opt/vpn-platform"
  }))

  tags = merge(var.tags, { environment = var.environment })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "public_ip" {
  value = azurerm_public_ip.vpn.ip_address
}

output "ssh_command" {
  value = "ssh ubuntu@${azurerm_public_ip.vpn.ip_address}"
}

output "proxy_endpoint" {
  value = "http://${azurerm_public_ip.vpn.ip_address}:${var.vpn_proxy_port}"
}
