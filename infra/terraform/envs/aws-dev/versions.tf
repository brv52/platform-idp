terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }

  # Local state on purpose: this environment lives for a few hours and is
  # destroyed from the same machine. For a shared environment switch to:
  #
  # backend "s3" {
  #   bucket       = "<state-bucket>"
  #   key          = "platform-idp/aws-dev.tfstate"
  #   region       = "eu-central-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}
