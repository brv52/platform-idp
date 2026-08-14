output "network_id" {
  description = "VNet ID."
  value       = azurerm_virtual_network.this.id
}

output "cidr" {
  description = "VNet address space."
  value       = var.cidr
}

output "node_subnet_ids" {
  description = "Node subnet, as a list to match the AWS module."
  value       = [azurerm_subnet.nodes.id]
}
