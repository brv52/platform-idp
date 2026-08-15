data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  partition = data.aws_partition.current.partition

  # Spot capacity is fragmented per instance type; giving the node group a
  # few interchangeable types makes "InsufficientInstanceCapacity" rare.
  spot_alternatives = {
    "t3.medium" = ["t3.medium", "t3a.medium", "t2.medium"]
    "t3.large"  = ["t3.large", "t3a.large", "m5.large"]
  }
}

# ---------------------------------------------------------------- control plane

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.node_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.api_allowed_cidrs
  }

  access_config {
    authentication_mode = "API"
    # The identity running apply (an SSO role session) becomes cluster admin
    # through an access entry, so no aws-auth ConfigMap is involved.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Short-lived environment: don't silently pay for extended support if the
  # cluster outlives its version.
  upgrade_policy {
    support_type = "STANDARD"
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# IRSA: lets service accounts assume IAM roles through the cluster's OIDC issuer.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[length(data.tls_certificate.oidc.certificates) - 1].sha1_fingerprint]
  tags            = var.tags
}

# ---------------------------------------------------------------- nodes

resource "aws_iam_role" "node" {
  name = "${var.name}-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_pools

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids
  version         = var.kubernetes_version

  capacity_type  = each.value.spot ? "SPOT" : "ON_DEMAND"
  instance_types = each.value.spot ? lookup(local.spot_alternatives, each.value.size, [each.value.size]) : [each.value.size]
  ami_type       = "AL2023_x86_64_STANDARD"
  disk_size      = 30

  scaling_config {
    min_size     = each.value.min
    max_size     = each.value.max
    desired_size = each.value.desired
  }

  update_config {
    max_unavailable = 1
  }

  labels = merge(each.value.labels, { "platform-idp/pool" = each.key })
  tags   = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------- add-ons

resource "aws_eks_addon" "this" {
  for_each = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  # coredns needs schedulable nodes before it reports healthy.
  depends_on = [aws_eks_node_group.this]
}
