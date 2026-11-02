# One-time setup that lets GitLab CI/CD talk to AWS without any stored keys.
#
#   GitLab job ──(signed OIDC ID token)──▶ AWS STS ──▶ short-lived credentials
#
# AWS trusts tokens issued by GitLab, but only for one project and one branch,
# so feature branches, forks and other projects can never deploy.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  gitlab_host = trimprefix(trimprefix(var.gitlab_url, "https://"), "http://")
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id

  # IAM roles the pipeline is allowed to create/manage (EKS cluster + node roles).
  managed_roles_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*"

  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.gitlab[0].arn
    : data.aws_iam_openid_connect_provider.gitlab[0].arn
  )
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count = var.create_oidc_provider ? 1 : 0

  url            = var.gitlab_url
  client_id_list = [var.gitlab_url]
}

data "aws_iam_openid_connect_provider" "gitlab" {
  count = var.create_oidc_provider ? 0 : 1
  url   = var.gitlab_url
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "GitLabOidc"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_host}:aud"
      values   = [var.gitlab_url]
    }

    # Token subject format: project_path:<group>/<project>:ref_type:branch:ref:<branch>
    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_host}:sub"
      values   = ["project_path:${var.gitlab_project_path}:ref_type:branch:ref:${var.gitlab_branch}"]
    }
  }
}

# Deliberately NOT named "<project>-*", so the pipeline cannot edit its own role.
resource "aws_iam_role" "gitlab_ci" {
  name                 = "gitlab-ci-${var.project}"
  description          = "Assumed by GitLab CI/CD (${var.gitlab_project_path}@${var.gitlab_branch}) via OIDC"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Everything except IAM/Organizations (VPC, EKS, RDS, CloudWatch, ...).
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.gitlab_ci.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# IAM is the privilege-escalation risk, so the pipeline only gets a narrow slice:
# it can manage "<project>-*" roles and attach AWS-managed EKS/ECR policies to them,
# nothing else (no inline policies, no AdministratorAccess, no users).
data "aws_iam_policy_document" "scoped_iam" {
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:PassRole",
    ]
    resources = [local.managed_roles_arn]
  }

  statement {
    sid       = "AttachApprovedManagedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.managed_roles_arn]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.partition}:iam::aws:policy/AmazonEKS*",
        "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
      ]
    }
  }
}

resource "aws_iam_policy" "scoped_iam" {
  name        = "gitlab-ci-${var.project}-iam"
  description = "Scoped IAM permissions for the ${var.project} GitLab pipeline"
  policy      = data.aws_iam_policy_document.scoped_iam.json
}

resource "aws_iam_role_policy_attachment" "scoped_iam" {
  role       = aws_iam_role.gitlab_ci.name
  policy_arn = aws_iam_policy.scoped_iam.arn
}
