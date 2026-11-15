locals {
  cluster_name = "inference-router-staging"
  eks_prefix   = "arn:aws:eks:${local.region}:${local.account_id}"
  ec2_prefix   = "arn:aws:ec2:${local.region}:${local.account_id}"
  iam_prefix   = "arn:aws:iam::${local.account_id}"
  worker_iam_roles = [
    for name in ["workers", "vpc-cni", "cluster-admin", "session-host"] :
    "${local.iam_prefix}:role/${local.cluster_name}-${name}"
  ]
  session_profile_arn = "${local.iam_prefix}:instance-profile/${local.cluster_name}-session-host"
  cluster_arn         = "${local.eks_prefix}:cluster/${local.cluster_name}"
  node_group_arn      = "${local.eks_prefix}:nodegroup/${local.cluster_name}/staging-general/*"
  worker_template_arn = "${local.ec2_prefix}:launch-template/lt-0b07fdcd81113feea"
  addon_arns          = [for name in ["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"] : "${local.eks_prefix}:addon/${local.cluster_name}/${name}/*"]
  access_entry_arn    = "${local.eks_prefix}:access-entry/${local.cluster_name}/role/${local.account_id}/${local.cluster_name}-cluster-admin/*"
  pod_identity_arn    = "${local.eks_prefix}:podidentityassociation/${local.cluster_name}/*"
}

resource "aws_iam_role_policy" "read_workers" {
  for_each = aws_iam_role.github

  name = "read-staging-workers"
  role = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          # The AWS provider reads the EIP domain-name attribute immediately after allocation.
          "ec2:DescribeAddresses", "ec2:DescribeAddressesAttribute", "ec2:DescribeInternetGateways", "ec2:DescribeNatGateways",
          "ec2:DescribeSecurityGroupRules", "ec2:DescribeLaunchTemplates", "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstances", "ec2:DescribeInstanceAttribute", "ec2:DescribeInstanceTypes", "ec2:DescribeVolumes",
          "ec2:DescribeInstanceCreditSpecifications", "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:DescribeNetworkInterfaces", "ec2:DescribeImages", "ec2:DescribeTags",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeNodegroup", "eks:DescribeAddon", "eks:DescribeAccessEntry", "eks:ListAssociatedAccessPolicies", "eks:DescribePodIdentityAssociation", "eks:ListPodIdentityAssociations", "eks:ListTagsForResource"]
        Resource = concat([local.cluster_arn, local.node_group_arn, local.access_entry_arn, local.pod_identity_arn], local.addon_arns)
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:ListRoleTags"]
        Resource = local.worker_iam_roles
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile", "iam:ListInstanceProfileTags"]
        Resource = local.session_profile_arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "write_workers" {
  count = var.apply_trust_until == null ? 0 : 1

  name = "write-staging-workers-during-approval"
  role = aws_iam_role.github["apply"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateInternetGateway", "ec2:AttachInternetGateway", "ec2:AllocateAddress",
          "ec2:CreateNatGateway", "ec2:CreateRouteTable", "ec2:CreateRoute", "ec2:AssociateRouteTable",
          "ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:CreateLaunchTemplate", "ec2:CreateTags",
        ]
        Resource = concat(
          ["${local.ec2_prefix}:vpc/vpc-0f2e0c1fed729fa19"],
          [for kind in ["subnet", "internet-gateway", "elastic-ip", "natgateway", "route-table", "security-group", "security-group-rule", "launch-template", "network-interface", "volume", "instance"] : "${local.ec2_prefix}:${kind}/*"],
        )
      },
      {
        Effect    = "Allow"
        Action    = "ec2:RunInstances"
        Resource  = "${local.ec2_prefix}:instance/*"
        Condition = { StringEquals = { "ec2:InstanceType" = "t4g.micro" } }
      },
      {
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:${local.region}::image/ami-0c09db4d8b86a32d2",
          "${local.ec2_prefix}:subnet/subnet-032496e6d4b5eafa2",
          "${local.ec2_prefix}:security-group/*",
          "${local.ec2_prefix}:network-interface/*",
          "${local.ec2_prefix}:volume/*",
        ]
      },
      {
        # EKS checks RunInstances on the caller when it validates the worker launch template.
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2_prefix}:instance/*"
        Condition = {
          ArnEquals    = { "ec2:LaunchTemplate" = local.worker_template_arn }
          StringEquals = { "ec2:InstanceType" = "t3.medium" }
        }
      },
      {
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          local.worker_template_arn,
          "arn:aws:ec2:${local.region}::image/ami-00b78a1637f77b388",
          "arn:aws:ec2:${local.region}::snapshot/snap-0750d3253b9664da2",
          "${local.ec2_prefix}:subnet/subnet-032496e6d4b5eafa2",
          "${local.ec2_prefix}:subnet/subnet-00bd98842fefd8928",
          "${local.ec2_prefix}:security-group/sg-0fdd2d911edbcd315",
          "${local.ec2_prefix}:security-group/sg-034c1beb99ae934a1",
          "${local.ec2_prefix}:network-interface/*",
          "${local.ec2_prefix}:volume/*",
        ]
        Condition = { ArnEquals = { "ec2:LaunchTemplate" = local.worker_template_arn } }
      },
      {
        Effect   = "Allow"
        Action   = ["eks:CreateNodegroup", "eks:CreateAddon", "eks:CreatePodIdentityAssociation", "eks:CreateAccessEntry", "eks:AssociateAccessPolicy", "eks:TagResource"]
        Resource = concat([local.cluster_arn, local.node_group_arn, local.access_entry_arn, local.pod_identity_arn], local.addon_arns)
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:TagRole"]
        Resource = local.worker_iam_roles
      },
      {
        Effect   = "Allow"
        Action   = "iam:AttachRolePolicy"
        Resource = local.worker_iam_roles
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = [
              for name in ["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonEKS_CNI_Policy", "AmazonSSMManagedInstanceCore"] :
              "arn:aws:iam::aws:policy/${name}"
            ]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [for name in ["workers", "vpc-cni", "session-host"] : "${local.iam_prefix}:role/${local.cluster_name}-${name}"]
        Condition = {
          StringEquals = { "iam:PassedToService" = ["ec2.amazonaws.com", "eks.amazonaws.com", "pods.eks.amazonaws.com"] }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateInstanceProfile", "iam:TagInstanceProfile", "iam:AddRoleToInstanceProfile"]
        Resource = local.session_profile_arn
      },
      {
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = ["${local.iam_prefix}:role/aws-service-role/eks-nodegroup.amazonaws.com/*", "${local.iam_prefix}:role/aws-service-role/autoscaling.amazonaws.com/*"]
        Condition = {
          StringEquals = { "iam:AWSServiceName" = ["eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com"] }
        }
      },
    ]
  })
}
