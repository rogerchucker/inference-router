resource "aws_iam_role" "verify" {
  for_each = local.environments

  name                 = "inference-router-${each.key}-verify"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = "arn:aws:iam::${local.account}:oidc-provider/${local.oidc_host}" }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "repo:${local.oidc_repository}:environment:${each.key}-verify"
        }
      }
    }]
  })

  depends_on = [github_repository_environment_deployment_policy.main]
}

resource "aws_iam_role_policy" "verify" {
  for_each = local.environments

  name = "verify-private-eks-rollout"
  role = aws_iam_role.verify[each.key].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${local.region}:${local.account}:cluster/${data.terraform_remote_state.cluster[each.key].outputs.cluster_name}"
      },
      {
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ec2:${local.region}:${local.account}:instance/${data.terraform_remote_state.cluster[each.key].outputs.session_host_instance_id}"
        Condition = {
          Bool = { "ssm:SessionDocumentAccessCheck" = true }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ssm:${local.region}::document/AWS-StartPortForwardingSessionToRemoteHost"
      },
      {
        Effect   = "Allow"
        Action   = ["ssmmessages:OpenDataChannel", "ssm:TerminateSession"]
        Resource = "arn:aws:ssm:${local.region}:${local.account}:session/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/aws:ssmmessages:session-id" = "$${aws:userid}"
            "ssm:resourceTag/aws:ssmmessages:target-id"  = data.terraform_remote_state.cluster[each.key].outputs.session_host_instance_id
          }
        }
      },
    ]
  })
}

resource "aws_eks_access_entry" "verify" {
  for_each = local.environments

  cluster_name      = data.terraform_remote_state.cluster[each.key].outputs.cluster_name
  principal_arn     = aws_iam_role.verify[each.key].arn
  type              = "STANDARD"
  kubernetes_groups = [local.groups[each.key]]
}
