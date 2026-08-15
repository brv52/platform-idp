# Shared cluster contract, see ../README.md.

variable "name" {
  description = "Cluster name and resource prefix."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.37\"."
  type        = string
}

variable "node_subnet_ids" {
  description = "Subnets for nodes and control plane ENIs (at least two AZs)."
  type        = list(string)

  validation {
    condition     = length(var.node_subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two availability zones."
  }
}

variable "node_pools" {
  description = "Node pools keyed by name. A \"system\" pool is required."
  type = map(object({
    size    = string
    min     = number
    max     = number
    desired = number
    spot    = optional(bool, false)
    labels  = optional(map(string), {})
  }))

  validation {
    condition     = contains(keys(var.node_pools), "system")
    error_message = "node_pools must contain a \"system\" pool."
  }

  validation {
    condition     = alltrue([for p in values(var.node_pools) : p.min <= p.desired && p.desired <= p.max])
    error_message = "Every pool needs min <= desired <= max."
  }
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
