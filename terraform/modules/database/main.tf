# Managed PostgreSQL (Amazon RDS) for one application environment.
# Stateful data lives outside Kubernetes: AWS handles backups, patching and
# storage, and the cluster can be rebuilt without touching the data.

resource "random_password" "master" {
  length  = 32
  special = false # alphanumeric only: safe inside a connection URL
}

resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.identifier}-db"
  description = "PostgreSQL for ${var.identifier}: reachable only from the private (pod) subnets"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  count = length(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL from EKS pods"
  cidr_ipv4         = var.allowed_cidr_blocks[count.index]
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
}

resource "aws_db_instance" "this" {
  identifier = var.identifier

  engine                     = "postgres"
  engine_version             = var.engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true
  deletion_protection     = var.deletion_protection
  # Portfolio setting: lets `terraform destroy` finish without leaving snapshots behind.
  skip_final_snapshot = true
}
