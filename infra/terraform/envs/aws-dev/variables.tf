variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Environment / cluster name."
  type        = string
  default     = "platform-idp-dev"
}

variable "kubernetes_version" {
  description = "EKS minor version."
  type        = string
  default     = "1.37"
}

variable "api_allowed_cidrs" {
  description = "Who may reach the EKS public endpoint. Set to your egress IP: -var 'api_allowed_cidrs=[\"203.0.113.7/32\"]'."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "brv52"
}

variable "budget_email" {
  description = "If set, an AWS Budget alerts this address at 50% and 100% of budget_usd."
  type        = string
  default     = ""
}

variable "budget_usd" {
  description = "Monthly cost budget for the account, in USD."
  type        = number
  default     = 5
}
