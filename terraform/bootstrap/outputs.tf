output "gitlab_ci_role_arn" {
  description = "Store this as the GitLab CI/CD variable AWS_ROLE_ARN (Settings → CI/CD → Variables, protected)."
  value       = aws_iam_role.gitlab_ci.arn
}

output "oidc_provider_arn" {
  description = "IAM OIDC identity provider that trusts GitLab ID tokens."
  value       = local.oidc_provider_arn
}
