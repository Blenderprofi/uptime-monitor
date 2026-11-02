# Amazon EKS in Auto Mode.
#
# Auto Mode means AWS runs and patches the node lifecycle (Karpenter-based
# autoscaling), the VPC CNI, the EBS CSI driver and the load balancer controller
# that turns Kubernetes Ingress objects into Application Load Balancers.
# This stack therefore needs no node groups and no Helm-installed controllers.

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

# ---------------------------------------------------------------------------
# IAM: role assumed by the EKS control plane
# ---------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "AmazonEKSClusterPolicy",
    "AmazonEKSComputePolicy",
    "AmazonEKSBlockStoragePolicy",
    "AmazonEKSLoadBalancingPolicy",
    "AmazonEKSNetworkingPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# IAM: role for the EC2 instances that Auto Mode launches
# ---------------------------------------------------------------------------
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = ["sts:AssumeRole"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodeMinimalPolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

# Created up front so the logs get a retention period (EKS would otherwise
# create the group itself with "never expire" and leave it behind on destroy).
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Auto Mode manages networking/DNS itself; don't install the legacy self-managed add-ons.
  bootstrap_self_managed_addons = false

  access_config {
    # IAM access entries only (no aws-auth ConfigMap). Admins are granted explicitly below.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    # Public endpoint so hosted GitLab runners can reach the API; restrict the CIDRs if your runners have fixed IPs.
    endpoint_public_access = true
    public_access_cidrs    = var.endpoint_public_access_cidrs
  }

  # Fail upgrades loudly instead of silently paying for extended support.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# Who may use kubectl: explicit IAM access entries (the CI role + any humans)
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ---------------------------------------------------------------------------
# metrics-server feeds CPU/memory usage to the HorizontalPodAutoscaler
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
