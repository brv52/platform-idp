output "network_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "node_subnet_ids" {
  description = "Subnets for nodes and the EKS control plane ENIs: private when nat_mode = single, public otherwise."
  value       = var.nat_mode == "single" ? aws_subnet.private[*].id : aws_subnet.public[*].id
}

output "public_subnet_ids" {
  description = "Public subnets (internet-facing load balancers)."
  value       = aws_subnet.public[*].id
}
