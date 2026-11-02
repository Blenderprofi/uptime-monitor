output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "admin_access_policy_ids" {
  description = "Depend on this to make sure kubectl/Terraform access exists before touching the API."
  value       = [for association in aws_eks_access_policy_association.admin : association.id]
}
