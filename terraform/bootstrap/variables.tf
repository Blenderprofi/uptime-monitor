variable "aws_region" {
  description = "AWS region used for API calls (IAM itself is global)."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Project name. Must match `project` in the main stack: the CI role may only manage IAM roles named \"<project>-*\"."
  type        = string
  default     = "pulsewatch"
}

variable "gitlab_url" {
  description = "Base URL of the GitLab instance that issues the CI/CD ID tokens."
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_project_path" {
  description = "Full path of the GitLab project allowed to assume the role, e.g. \"my-group/uptime-monitor\"."
  type        = string

  validation {
    condition     = can(regex("^[^/\\s]+(/[^/\\s]+)+$", var.gitlab_project_path))
    error_message = "Use the full project path, e.g. \"my-group/uptime-monitor\"."
  }
}

variable "gitlab_branch" {
  description = "Only pipelines on this branch can obtain AWS credentials. Protect it in GitLab."
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = "Set to false if this AWS account already has an IAM OIDC provider for the GitLab URL."
  type        = bool
  default     = true
}
