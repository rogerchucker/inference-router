locals {
  cluster = "inference-router-dev"
  eks     = "arn:aws:eks:${local.region}:${local.account}"
  iam     = "arn:aws:iam::${local.account}"

  cluster_arn = "${local.eks}:cluster/${local.cluster}"
  addons = [
    for name in ["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"] :
    "${local.eks}:addon/${local.cluster}/${name}/*"
  ]
  node_group   = "${local.eks}:nodegroup/${local.cluster}/dev-general/*"
  access_entry = "${local.eks}:access-entry/${local.cluster}/role/${local.account}/${local.cluster}-cluster-admin/*"
  pod_identity = "${local.eks}:podidentityassociation/${local.cluster}/*"
}

resource "aws_iam_role_policy" "read_dev" {
  for_each = aws_iam_role.github

  name = "read-dev-infrastructure"
  role = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # These EC2 discovery calls do not accept individual resource ARNs.
        Effect = "Allow"
        Action = [
          "ec2:DescribeAddresses",
          "ec2:DescribeAddressesAttribute",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeInstanceCreditSpecifications",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstances",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeNatGateways",
          "ec2:DescribeNetworkAcls",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeVpcs",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListPodIdentityAssociations"]
        Resource = local.cluster_arn
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeAddon"]
        Resource = local.addons
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeNodegroup"]
        Resource = local.node_group
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeAccessEntry", "eks:ListAssociatedAccessPolicies"]
        Resource = local.access_entry
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribePodIdentityAssociation"]
        Resource = local.pod_identity
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeUpdate", "eks:ListTagsForResource"]
        Resource = concat([local.cluster_arn, local.node_group, local.access_entry, local.pod_identity], local.addons)
      },
      {
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
        ]
        Resource = [
          for name in ["control-plane", "workers", "vpc-cni", "cluster-admin", "session-host"] :
          "${local.iam}:role/${local.cluster}-${name}"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iam:GetRole"]
        Resource = [
          "${local.iam}:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS",
          "${local.iam}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup",
          "${local.iam}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile", "iam:ListInstanceProfileTags"]
        Resource = "${local.iam}:instance-profile/${local.cluster}-session-host"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account}:secret:inference-router/dev/providers-??????"
      },
    ]
  })
}
