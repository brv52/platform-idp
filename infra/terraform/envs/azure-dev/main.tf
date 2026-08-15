locals {
  tags = {
    Project     = "platform-idp"
    Environment = "dev"
    Owner       = var.owner
    ManagedBy   = "terraform"
    Lifetime    = "ephemeral"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "../../modules/network/azure"

  name                = var.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  cidr                = "10.50.0.0/16"
  tags                = local.tags
}

module "cluster" {
  source = "../../modules/aks"

  name                = var.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  kubernetes_version  = var.kubernetes_version
  node_subnet_ids     = module.network.node_subnet_ids
  api_allowed_cidrs   = var.api_allowed_cidrs
  tags                = local.tags

  node_pools = {
    # Single burstable on-demand node: AKS system pools cannot be spot.
    system = { size = var.system_vm_size, min = 1, max = 1, desired = 1 }
  }
}
