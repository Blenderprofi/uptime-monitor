output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster (your IAM identity must be in cluster_admin_arns)."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "namespaces" {
  description = "Kubernetes namespace per environment."
  value       = { for env, ns in kubernetes_namespace_v1.app : env => ns.metadata[0].name }
}

output "database_endpoints" {
  description = "Private RDS endpoints per environment (reachable only from inside the VPC)."
  value       = { for env, db in module.database : env => "${db.address}:${db.port}" }
}
