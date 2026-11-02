variable "identifier" {
  description = "RDS instance identifier, e.g. \"pulsewatch-staging\"."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets (at least two AZs) for the DB subnet group."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDRs allowed to connect on 5432 (the private subnets where pods get their IPs)."
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL major version. Matches the postgres:16 image used locally and in CI."
  type        = string
  default     = "16"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper limit for storage autoscaling in GiB."
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ (doubles the cost)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "database_name" {
  type    = string
  default = "pulsewatch"
}

variable "username" {
  type    = string
  default = "pulsewatch"
}
