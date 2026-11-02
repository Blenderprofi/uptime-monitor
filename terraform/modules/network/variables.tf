variable "name" {
  description = "Name prefix for all network resources."
  type        = string
}

variable "cidr" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "Use a valid CIDR of /16 or larger (private subnets are carved out as /20s)."
  }
}

variable "az_count" {
  description = "Number of availability zones to span. EKS and RDS both require at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheap) instead of one per AZ (highly available)."
  type        = bool
  default     = true
}
