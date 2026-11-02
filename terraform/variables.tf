variable "aws_region" {
  description = "AWS region for every resource."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Name used for the cluster, the namespaces and as a resource prefix."
  type        = string
  default     = "pulsewatch"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway between AZs to save cost. Set to false for zone-redundant egress."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "cluster_admin_arns" {
  description = "IAM roles/users with cluster-admin. Must include the GitLab CI role (the pipeline passes it automatically)."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_arns) > 0
    error_message = "At least one admin is required, otherwise nobody (not even the pipeline) can deploy."
  }

  validation {
    condition = alltrue([
      for arn in var.cluster_admin_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+$", arn))
    ])
    error_message = "Use IAM role or user ARNs (arn:aws:iam::<account>:role/<name>), not STS assumed-role session ARNs."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Who can reach the Kubernetes API. GitLab.com hosted runners have no fixed IPs, hence the open default."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "environments" {
  description = "Application environments. Each gets its own namespace, secrets and RDS database in the shared cluster."
  type = map(object({
    db_instance_class     = string
    db_multi_az           = bool
    db_backup_retention   = number
    db_deletion_protected = bool
  }))

  default = {
    staging = {
      db_instance_class     = "db.t4g.micro"
      db_multi_az           = false
      db_backup_retention   = 1
      db_deletion_protected = false
    }
    production = {
      db_instance_class     = "db.t4g.micro"
      db_multi_az           = false # set to true for a real production workload
      db_backup_retention   = 7
      db_deletion_protected = false # set to true once the environment holds real data
    }
  }

  validation {
    condition     = alltrue([for name in keys(var.environments) : can(regex("^[a-z][a-z0-9-]{1,20}$", name))])
    error_message = "Environment names must be short, lowercase DNS labels (they become namespace names)."
  }
}
