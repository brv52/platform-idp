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
  description = "Node subnet(s); the first one is used."
  type        = list(string)

  validation {
    condition     = length(var.node_subnet_ids) >= 1
    error_message = "At least one node subnet is required."
  }
}

variable "node_pools" {
  description = "Node pools keyed by name. A \"system\" pool is required and is always on-demand."
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

  validation {
    # AKS pool names: lowercase alphanumeric, max 12 chars (Linux).
    condition     = alltrue([for k in keys(var.node_pools) : can(regex("^[a-z][a-z0-9]{0,11}$", k))])
    error_message = "AKS node pool names must be lowercase alphanumeric, 1-12 characters."
  }
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Empty means unrestricted."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# AKS-specific.

variable "resource_group_name" {
  description = "Resource group for the cluster."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "admin_principal_ids" {
  description = "Entra object IDs granted Azure Kubernetes Service RBAC Cluster Admin. The caller is always added."
  type        = list(string)
  default     = []
}
