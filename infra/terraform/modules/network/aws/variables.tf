variable "name" {
  description = "Prefix for all resource names; also used for the EKS cluster discovery tags."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR. Split into /20 subnets: public first, then private."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones. EKS needs subnets in at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_mode" {
  description = <<-EOT
    "single": one NAT gateway shared by all private subnets (cheapest HA-less option).
    "none":   no NAT; node_subnet_ids returns the public subnets and nodes get public IPs.
  EOT
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "none"], var.nat_mode)
    error_message = "nat_mode must be \"single\" or \"none\"."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
