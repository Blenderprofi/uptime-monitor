# Unit tests for the infrastructure code.
#
# `terraform test` runs these against mocked AWS/Kubernetes providers: nothing is
# created and no credentials are needed, so the pipeline runs them on every commit.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://mock.eks.eu-central-1.amazonaws.com"
      certificate_authority = [{ data = "bW9jay1jYQ==" }]
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "mock.abcdefghij.eu-central-1.rds.amazonaws.com"
      port    = 5432
    }
  }
}

mock_provider "kubernetes" {}

variables {
  cluster_admin_arns = ["arn:aws:iam::123456789012:role/gitlab-ci-pulsewatch"]
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
run "network_spans_two_azs_with_private_pod_subnets" {
  command = apply

  module {
    source = "./modules/network"
  }

  variables {
    name = "test"
  }

  assert {
    condition     = length(distinct(aws_subnet.private[*].availability_zone)) == 2
    error_message = "Private subnets must be spread over two availability zones."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : endswith(s.cidr_block, "/20")])
    error_message = "Private subnets must be /20 so the VPC CNI has enough pod IPs."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "Public subnets must be tagged for internet-facing load balancers."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "Nothing should get a public IP automatically."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "Default should be a single (cost-saving) NAT gateway."
  }
}

run "network_supports_one_nat_gateway_per_az" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    name               = "test"
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "Expected one NAT gateway per AZ."
  }
}

run "network_rejects_too_small_vpc" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    name = "test"
    cidr = "10.0.0.0/24"
  }

  expect_failures = [var.cidr]
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------
run "eks_auto_mode_with_explicit_admins" {
  command = apply

  module {
    source = "./modules/eks"
  }

  variables {
    cluster_name                 = "test"
    kubernetes_version           = "1.35"
    subnet_ids                   = ["subnet-a", "subnet-b"]
    admin_principal_arns         = ["arn:aws:iam::123456789012:role/gitlab-ci-test", "arn:aws:iam::123456789012:role/admin"]
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = aws_eks_cluster.this.compute_config[0].enabled
    error_message = "EKS Auto Mode must be enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "Use EKS access entries, not the aws-auth ConfigMap."
  }

  assert {
    condition     = !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions
    error_message = "Cluster admins must be explicit, not implied by whoever created the cluster."
  }

  assert {
    condition     = length(aws_eks_access_policy_association.admin) == 2
    error_message = "Every admin principal needs an access policy association."
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access
    error_message = "Nodes must reach the API server privately."
  }

  assert {
    condition     = startswith(aws_iam_role.cluster.name, "test-") && startswith(aws_iam_role.node.name, "test-")
    error_message = "IAM role names must start with the project prefix (the CI role may only manage those)."
  }
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
run "database_is_private_and_encrypted" {
  command = apply

  module {
    source = "./modules/database"
  }

  variables {
    identifier          = "test-staging"
    vpc_id              = "vpc-123"
    subnet_ids          = ["subnet-a", "subnet-b"]
    allowed_cidr_blocks = ["10.0.16.0/20", "10.0.32.0/20"]
  }

  assert {
    condition     = !aws_db_instance.this.publicly_accessible
    error_message = "The database must not be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted
    error_message = "Storage must be encrypted at rest."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.postgres : r.from_port == 5432 && r.to_port == 5432])
    error_message = "Only PostgreSQL may be opened."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.postgres : r.cidr_ipv4 != "0.0.0.0/0"])
    error_message = "The database must not be reachable from the internet."
  }

  assert {
    condition     = startswith(output.connection_url, "postgresql+psycopg://") && endswith(output.connection_url, "?sslmode=require")
    error_message = "DATABASE_URL must use the psycopg driver and require TLS."
  }
}

# ---------------------------------------------------------------------------
# Whole stack
# ---------------------------------------------------------------------------
run "each_environment_gets_namespace_secret_and_database" {
  command = apply

  assert {
    condition     = output.namespaces == { staging = "pulsewatch-staging", production = "pulsewatch-production" }
    error_message = "Expected one namespace per environment."
  }

  assert {
    condition = alltrue([
      for ns in kubernetes_namespace_v1.app : ns.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted"
    ])
    error_message = "Namespaces must enforce the restricted Pod Security Standard."
  }

  assert {
    condition = alltrue([
      for s in kubernetes_secret_v1.app : toset(keys(s.data)) == toset(["DATABASE_URL", "SESSION_SECRET"])
    ])
    error_message = "Each app secret must provide exactly DATABASE_URL and SESSION_SECRET."
  }

  assert {
    condition     = kubernetes_secret_v1.app["staging"].data["DATABASE_URL"] != kubernetes_secret_v1.app["production"].data["DATABASE_URL"]
    error_message = "Staging and production must not share database credentials."
  }

  assert {
    condition     = random_password.session_secret["staging"].result != random_password.session_secret["production"].result
    error_message = "Each environment needs its own session secret."
  }
}

run "rejects_sts_session_arn_as_admin" {
  command = plan

  variables {
    cluster_admin_arns = ["arn:aws:sts::123456789012:assumed-role/gitlab-ci-pulsewatch/session"]
  }

  expect_failures = [var.cluster_admin_arns]
}
