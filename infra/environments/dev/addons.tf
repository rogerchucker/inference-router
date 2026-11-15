resource "aws_iam_role" "vpc_cni" {
  name = "inference-router-dev-vpc-cni"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = module.eks.cluster_arn
          "aws:RequestTag/kubernetes-namespace"       = "kube-system"
          "aws:RequestTag/kubernetes-service-account" = "aws-node"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_eks_addon" "network" {
  for_each = {
    eks-pod-identity-agent = "v1.4.1-eksbuild.3"
    kube-proxy             = "v1.37.0-eksbuild.39"
  }

  cluster_name  = module.eks.cluster_name
  addon_name    = each.key
  addon_version = each.value
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "vpc-cni"
  addon_version = "v1.22.4-eksbuild.14"

  pod_identity_association {
    service_account = "aws-node"
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [
    aws_eks_addon.network["eks-pod-identity-agent"],
    aws_iam_role_policy_attachment.vpc_cni,
  ]
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "coredns"
  addon_version = "v1.14.7-eksbuild.35"

  depends_on = [aws_eks_node_group.workers]
}
