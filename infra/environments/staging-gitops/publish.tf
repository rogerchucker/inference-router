resource "aws_ecr_repository" "router" {
  name                 = local.repository
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_iam_role" "publish" {
  name = "inference-router-staging-publish"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:rogerchucker@335912/inference-router@1457504171:environment:staging-publish"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "publish" {
  name = "publish-inference-router-image"
  role = aws_iam_role.publish.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "ecr:GetAuthorizationToken"
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.router.arn
      },
    ]
  })
}

resource "github_repository_environment" "publish" {
  repository  = local.repository
  environment = "staging-publish"
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "publish" {
  repository     = local.repository
  environment    = github_repository_environment.publish.environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "publish" {
  for_each = {
    AWS_REGION         = local.region
    ECR_REPOSITORY_URL = aws_ecr_repository.router.repository_url
    IMAGE_PUBLISH_ROLE = aws_iam_role.publish.arn
  }

  repository    = local.repository
  environment   = github_repository_environment.publish.environment
  variable_name = each.key
  value         = each.value
}

output "repository_url" {
  value = aws_ecr_repository.router.repository_url
}
