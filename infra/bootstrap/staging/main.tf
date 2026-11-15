terraform {
  required_version = "~> 1.17.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = ["922763798103"]
}

locals {
  account_id = "922763798103"
  region     = "us-west-2"
  # This repository uses GitHub's immutable OIDC subjects.
  repository = "rogerchucker@335912/inference-router@1457504171"
  oidc_host  = "token.actions.githubusercontent.com"
  state_key  = "inference-router/staging/terraform.tfstate"
}

resource "aws_s3_bucket" "state" {
  bucket = "inference-router-tfstate-${local.account_id}-${local.region}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github" {
  for_each = toset(["plan", "apply"])

  name = "inference-router-staging-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Enable the apply trust after its GitHub environment and approval gate exist.
      Effect    = each.key == "plan" || var.enable_apply_trust ? "Allow" : "Deny"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "repo:${local.repository}:environment:staging-${each.key}"
        }
      }
    }]
  })
}

variable "enable_apply_trust" {
  description = "Enable the staging apply role after its independent approval gate exists."
  type        = bool
  default     = false
  nullable    = false
}

resource "aws_iam_role_policy" "state" {
  for_each = aws_iam_role.github

  name = "terraform-state"
  role = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.state.arn
        Condition = {
          StringLike = {
            "s3:prefix" = [local.state_key, "${local.state_key}.tflock", "inference-router/staging/workspaces/*"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = each.key == "apply" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"]
        Resource = "${aws_s3_bucket.state.arn}/${local.state_key}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/${local.state_key}.tflock"
      },
    ]
  })
}

resource "aws_iam_role_policy" "read_staging" {
  for_each = aws_iam_role.github

  name = "read-staging"
  role = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeAvailabilityZones", "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = local.region }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListTagsForResource"]
        Resource = "arn:aws:eks:${local.region}:${local.account_id}:cluster/inference-router-staging"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"]
        Resource = "arn:aws:iam::${local.account_id}:role/inference-router-staging-control-plane"
      },
    ]
  })
}

resource "aws_iam_role_policy" "write_staging" {
  name = "write-staging"
  role = aws_iam_role.github["apply"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateVpc", "ec2:CreateSubnet", "ec2:CreateTags", "ec2:ModifyVpcAttribute", "ec2:ModifySubnetAttribute"]
        Resource = ["arn:aws:ec2:${local.region}:${local.account_id}:vpc/*", "arn:aws:ec2:${local.region}:${local.account_id}:subnet/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["eks:CreateCluster", "eks:TagResource", "eks:DescribeUpdate", "eks:UpdateClusterConfig", "eks:UpdateClusterVersion"]
        Resource = "arn:aws:eks:${local.region}:${local.account_id}:cluster/inference-router-staging"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:TagRole"]
        Resource = "arn:aws:iam::${local.account_id}:role/inference-router-staging-control-plane"
      },
      {
        Effect   = "Allow"
        Action   = "iam:AttachRolePolicy"
        Resource = "arn:aws:iam::${local.account_id}:role/inference-router-staging-control-plane"
        Condition = {
          ArnEquals = { "iam:PolicyARN" = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/inference-router-staging-control-plane"
        Condition = {
          StringEquals = { "iam:PassedToService" = "eks.amazonaws.com" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "arn:aws:iam::${local.account_id}:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "eks.amazonaws.com" }
        }
      },
    ]
  })
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  value = aws_iam_role.github["plan"].arn
}

output "apply_role_arn" {
  value = aws_iam_role.github["apply"].arn
}
