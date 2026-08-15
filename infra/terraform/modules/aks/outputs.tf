# Shared cluster contract, see ../README.md.

locals {
  # With local accounts disabled kube_config only carries the server and CA.
  kc = azurerm_kubernetes_cluster.this.kube_config[0]
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server URL."
  value       = local.kc.host
}

output "cluster_ca_certificate" {
  description = "Cluster CA, PEM."
  value       = base64decode(local.kc.cluster_ca_certificate)
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer (Entra workload identity)."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubeconfig" {
  description = "Exec-based kubeconfig using kubelogin with the Azure CLI session; no embedded credentials."
  value = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = var.name
    clusters = [{
      name = var.name
      cluster = {
        server                     = local.kc.host
        certificate-authority-data = local.kc.cluster_ca_certificate
      }
    }]
    contexts = [{ name = var.name, context = { cluster = var.name, user = var.name } }]
    users = [{
      name = var.name
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "kubelogin"
          # 6dae42f8-... is the fixed application ID of the AKS AAD server.
          args = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
        }
      }
    }]
  })
}

output "node_pools" {
  description = "Effective node pool settings."
  value = merge(
    {
      system = {
        priority = "Regular"
        vm_size  = azurerm_kubernetes_cluster.this.default_node_pool[0].vm_size
        min      = local.system.min
        max      = local.system.max
        desired  = local.system.desired
      }
    },
    { for k, p in azurerm_kubernetes_cluster_node_pool.extra : k => {
      priority = p.priority
      vm_size  = p.vm_size
      min      = var.node_pools[k].min
      max      = var.node_pools[k].max
      desired  = var.node_pools[k].desired
    } }
  )
}
