variable "location" {
  description = "Azure region."
  type        = string
  default     = "germanywestcentral"
}

variable "name" {
  description = "Environment / cluster name."
  type        = string
  default     = "platform-idp-dev"
}

variable "kubernetes_version" {
  description = "AKS minor version."
  type        = string
  default     = "1.37"
}

variable "system_vm_size" {
  description = "System pool VM size (>= 2 vCPU / 4 GiB). Burstable by default."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "api_allowed_cidrs" {
  description = "Who may reach the AKS public endpoint. Empty = unrestricted; set to your egress IP."
  type        = list(string)
  default     = []
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "brv52"
}
