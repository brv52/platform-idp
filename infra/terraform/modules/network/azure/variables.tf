variable "name" {
  description = "Prefix for all resource names."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the VNet is created in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "cidr" {
  description = "VNet address space. The node subnet takes the first /20. Pod IPs come from the overlay CIDR, not from here."
  type        = string
  default     = "10.50.0.0/16"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
