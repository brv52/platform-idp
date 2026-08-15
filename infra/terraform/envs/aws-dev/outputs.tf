output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "oidc_issuer_url" {
  value = module.cluster.oidc_issuer_url
}

output "node_pools" {
  value = module.cluster.node_pools
}

output "kubeconfig" {
  description = "terraform output -raw kubeconfig > aws-dev.kubeconfig"
  value       = module.cluster.kubeconfig
}
