terraform {
  required_version = "~> 1.17.0"

  backend "s3" {
    bucket              = "inference-router-tfstate-922763798103-us-west-2"
    key                 = "inference-router/dev/bootstrap.tfstate"
    region              = "us-west-2"
    use_lockfile        = true
    encrypt             = true
    allowed_account_ids = ["922763798103"]
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

locals {
  account       = "922763798103"
  region        = "us-west-2"
  bucket_arn    = "arn:aws:s3:::inference-router-tfstate-${local.account}-${local.region}"
  state_key     = "inference-router/dev/terraform.tfstate"
  workspaces    = "inference-router/dev/workspaces/"
  github_owner  = "rogerchucker"
  github_repo   = "inference-router"
  oidc_host     = "token.actions.githubusercontent.com"
  oidc_repo     = "rogerchucker@335912/inference-router@1457504171"
  apply_enabled = var.apply_approval != null
}

provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account]
}

provider "github" {
  owner = local.github_owner
}

resource "aws_iam_role" "github" {
  for_each = toset(["plan", "apply"])

  name                 = "inference-router-dev-${each.key}"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = each.key == "plan" || local.apply_enabled ? "Allow" : "Deny"
      Principal = { Federated = "arn:aws:iam::${local.account}:oidc-provider/${local.oidc_host}" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = merge(
        {
          StringEquals = {
            "${local.oidc_host}:aud" = "sts.amazonaws.com"
            "${local.oidc_host}:sub" = "repo:${local.oidc_repo}:environment:dev-${each.key}"
          }
        },
        each.key == "apply" && local.apply_enabled ? {
          DateLessThan = { "aws:CurrentTime" = var.apply_approval.expires_at }
        } : {},
      )
    }]
  })

  lifecycle {
    precondition {
      condition = each.key != "apply" || !local.apply_enabled ? true : (
        timecmp(var.apply_approval.expires_at, plantimestamp()) > 0 &&
        timecmp(var.apply_approval.expires_at, timeadd(plantimestamp(), "2h")) <= 0
      )
      error_message = "Set the Dev apply expiry within two hours of the bootstrap plan, or omit apply_approval to close the window."
    }
  }
}

resource "aws_iam_role_policy" "state" {
  for_each = aws_iam_role.github

  name = "terraform-dev-state"
  role = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.bucket_arn
        Condition = {
          StringEquals = { "s3:prefix" = [local.state_key, "${local.state_key}.tflock", local.workspaces] }
        }
      },
      {
        Effect   = "Allow"
        Action   = each.key == "apply" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"]
        Resource = "${local.bucket_arn}/${local.state_key}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.bucket_arn}/${local.state_key}.tflock"
      },
    ]
  })
}
