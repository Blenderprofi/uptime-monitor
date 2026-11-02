# The "platform" half of each environment lives here, the "application" half in k8s/:
#
#   Terraform  → namespace (with Pod Security "restricted") + Secret with credentials
#   GitLab CI  → Deployments, Service, Ingress, HPA, ... (k8s/overlays/<env>)
#
# Credentials therefore go straight from Terraform into the cluster. They never
# appear in Git, in CI/CD variables or in job logs.

resource "random_password" "session_secret" {
  for_each = var.environments

  length  = 64
  special = false
}

resource "kubernetes_namespace_v1" "app" {
  for_each = var.environments

  metadata {
    name = "${var.project}-${each.key}"

    labels = {
      "app.kubernetes.io/part-of" = var.project
      "environment"               = each.key

      # Reject any pod that runs as root, escalates privileges, etc.
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    }
  }

  # Wait until the pipeline's IAM role has been granted cluster-admin.
  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "app" {
  for_each = var.environments

  metadata {
    name      = "${var.project}-app"
    namespace = kubernetes_namespace_v1.app[each.key].metadata[0].name

    labels = {
      "app.kubernetes.io/part-of"    = var.project
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    DATABASE_URL   = module.database[each.key].connection_url
    SESSION_SECRET = random_password.session_secret[each.key].result
  }
}
