# PulseWatch platform on AWS
#
#   VPC (2 AZs) ─┬─ public subnets:  ALBs (created from Kubernetes Ingress), NAT gateway
#                └─ private subnets: EKS Auto Mode nodes + pods, RDS PostgreSQL
#
# One EKS cluster hosts every environment in its own namespace; each environment
# gets a dedicated RDS instance so staging data can never leak into production.

module "network" {
  source = "./modules/network"

  name               = var.project
  cidr               = var.vpc_cidr
  az_count           = 2
  single_nat_gateway = var.single_nat_gateway
}

module "eks" {
  source = "./modules/eks"

  cluster_name                 = var.project
  kubernetes_version           = var.kubernetes_version
  subnet_ids                   = module.network.private_subnet_ids
  admin_principal_arns         = var.cluster_admin_arns
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

module "database" {
  source   = "./modules/database"
  for_each = var.environments

  identifier            = "${var.project}-${each.key}"
  vpc_id                = module.network.vpc_id
  subnet_ids            = module.network.private_subnet_ids
  allowed_cidr_blocks   = module.network.private_subnet_cidrs
  instance_class        = each.value.db_instance_class
  multi_az              = each.value.db_multi_az
  backup_retention_days = each.value.db_backup_retention
  deletion_protection   = each.value.db_deletion_protected
}
