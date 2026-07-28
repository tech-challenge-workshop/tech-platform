// Lets GitHub Actions deploy to the cluster without a long-lived access key.
// Each workflow run exchanges a short-lived OIDC token for AWS credentials, so
// there is no secret to rotate and nothing to leak from a repository setting.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = local.tags
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to the default branch of the listed repositories: a pull request
    # from a fork cannot assume this role, and neither can another repository
    # in the organisation.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for repo in var.github_deploy_repositories :
        "repo:${var.github_org}/${repo}:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  description        = "Assumed by GitHub Actions to deploy the services to EKS"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = local.tags
}

# All the role needs from the AWS API is enough to build a kubeconfig. Every
# permission inside the cluster comes from the EKS access entry below.
data "aws_iam_policy_document" "github_actions_eks" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_policy" "github_actions_eks" {
  name        = "${local.name}-github-actions-eks"
  description = "Read the EKS cluster endpoint and CA so the workflow can build a kubeconfig"
  policy      = data.aws_iam_policy_document.github_actions_eks.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "github_actions_eks" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_eks.arn
}
