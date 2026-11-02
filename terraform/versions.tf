terraform {
  required_version = ">= 1.9"

  # State is stored in GitLab's built-in Terraform state backend (encrypted at rest,
  # with locking). The pipeline configures it through TF_HTTP_* environment variables;
  # see docs/deployment.md for the equivalent `terraform init` command to run locally.
  backend "http" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
