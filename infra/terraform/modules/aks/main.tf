data "azurerm_client_config" "current" {}

locals {
  system      = var.node_pools["system"]
  extra_pools = { for k, v in var.node_pools : k => v if k != "system" }
  admins      = toset(concat([data.azurerm_client_config.current.object_id], var.admin_principal_ids))
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"

  # Workload identity federation through the cluster OIDC issuer.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Entra ID only: no static admin kubeconfig can be downloaded.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = local.system.size
    vnet_subnet_id               = var.node_subnet_ids[0]
    auto_scaling_enabled         = local.system.max > local.system.min
    node_count                   = local.system.desired
    min_count                    = local.system.max > local.system.min ? local.system.min : null
    max_count                    = local.system.max > local.system.min ? local.system.max : null
    os_disk_size_gb              = 30
    os_disk_type                 = "Managed"
    only_critical_addons_enabled = false
    node_labels                  = merge(local.system.labels, { "platform-idp/pool" = "system" })
    tags                         = var.tags

    upgrade_settings {
      max_surge = "1"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Required block since azurerm 5. Manual keeps the pools above authoritative
  # instead of handing node sizing to AKS node auto-provisioning.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "192.168.0.0/16"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_allowed_cidrs) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_allowed_cidrs
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "extra" {
  for_each = local.extra_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.size
  vnet_subnet_id        = var.node_subnet_ids[0]
  auto_scaling_enabled  = each.value.max > each.value.min
  node_count            = each.value.desired
  min_count             = each.value.max > each.value.min ? each.value.min : null
  max_count             = each.value.max > each.value.min ? each.value.max : null
  os_disk_size_gb       = 30

  priority        = each.value.spot ? "Spot" : "Regular"
  eviction_policy = each.value.spot ? "Delete" : null
  spot_max_price  = each.value.spot ? -1 : null # pay at most the on-demand price

  node_labels = merge(each.value.labels, { "platform-idp/pool" = each.key })
  # AKS adds this taint to spot pools anyway; declaring it avoids a perpetual diff.
  node_taints = each.value.spot ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : []
  tags        = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each             = local.admins
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
