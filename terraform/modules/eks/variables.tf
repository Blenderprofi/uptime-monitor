variable "cluster_name" {
  description = "EKS cluster name; also the prefix of its IAM roles."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.35\"."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane ENIs and the worker nodes."
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "IAM role/user ARNs that receive cluster-admin through EKS access entries."
  type        = list(string)
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint."
  type        = list(string)
}

variable "log_retention_days" {
  description = "Retention of the control plane logs in CloudWatch."
  type        = number
  default     = 7
}

variable "enable_metrics_server" {
  description = "Install the metrics-server EKS add-on (required for CPU-based autoscaling)."
  type        = bool
  default     = true
}
