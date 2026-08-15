# Shared cluster contract, see ../README.md.

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server URL."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Cluster CA, PEM."
  value       = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer (IRSA)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for IRSA trust policies."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "kubeconfig" {
  description = "Exec-based kubeconfig using `aws eks get-token`; no embedded credentials."
  value = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = var.name
    clusters = [{
      name = var.name
      cluster = {
        server                     = aws_eks_cluster.this.endpoint
        certificate-authority-data = aws_eks_cluster.this.certificate_authority[0].data
      }
    }]
    contexts = [{ name = var.name, context = { cluster = var.name, user = var.name } }]
    users = [{
      name = var.name
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "aws"
          args       = ["eks", "get-token", "--cluster-name", var.name, "--region", data.aws_region.current.region, "--output", "json"]
        }
      }
    }]
  })
}

output "node_pools" {
  description = "Effective node pool settings."
  value = { for k, g in aws_eks_node_group.this : k => {
    capacity_type  = g.capacity_type
    instance_types = g.instance_types
    min            = g.scaling_config[0].min_size
    max            = g.scaling_config[0].max_size
    desired        = g.scaling_config[0].desired_size
  } }
}
