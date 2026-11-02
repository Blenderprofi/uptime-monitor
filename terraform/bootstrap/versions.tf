terraform {
  required_version = ">= 1.9"

  # Bootstrap runs once, locally, with your own admin credentials. Its state is
  # tiny and contains no secrets, so local state is acceptable here.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
