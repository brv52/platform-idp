locals {
  tags = {
    Project     = "platform-idp"
    Environment = "dev"
    Owner       = var.owner
    ManagedBy   = "terraform"
    # Reminder for whoever finds this in the console: it is meant to be
    # destroyed the same day.
    Lifetime = "ephemeral"
  }
}

module "network" {
  source = "../../modules/network/aws"

  name     = var.name
  cidr     = "10.40.0.0/16"
  az_count = 2
  nat_mode = "single"
  tags     = local.tags
}

module "cluster" {
  source = "../../modules/eks"

  name               = var.name
  kubernetes_version = var.kubernetes_version
  node_subnet_ids    = module.network.node_subnet_ids
  api_allowed_cidrs  = var.api_allowed_cidrs
  tags               = local.tags

  node_pools = {
    system = { size = "t3.medium", min = 2, max = 3, desired = 2, spot = true }
  }
}

resource "aws_budgets_budget" "guard" {
  count = var.budget_email == "" ? 0 : 1

  name         = "${var.name}-guard"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
