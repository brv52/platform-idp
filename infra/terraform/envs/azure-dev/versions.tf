terraform {
  required_version = ">= 1.13.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
  }

  # Local state on purpose, see envs/aws-dev/versions.tf. Shared alternative:
  #
  # backend "azurerm" {
  #   resource_group_name  = "<tfstate-rg>"
  #   storage_account_name = "<tfstate-account>"
  #   container_name       = "tfstate"
  #   key                  = "platform-idp/azure-dev.tfstate"
  #   use_azuread_auth     = true
  # }
}

# Subscription comes from ARM_SUBSCRIPTION_ID (see ACTIONS.md); credentials
# from the Azure CLI session.
provider "azurerm" {
  features {
    resource_group {
      # The cluster creates resources (node RG, LB) that terraform does not
      # track; allow destroy to clean the whole group in one go.
      prevent_deletion_if_contains_resources = false
    }
  }
}
