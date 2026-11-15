resource "aws_iam_role" "workers" {
  name = "inference-router-staging-workers"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "workers" {
  for_each = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])

  role       = aws_iam_role.workers.name
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
}

resource "aws_launch_template" "workers" {
  name_prefix = "inference-router-staging-workers-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "staging-general"
  node_role_arn   = aws_iam_role.workers.arn
  subnet_ids      = toset([for subnet in aws_subnet.private : subnet.id])
  version         = var.kubernetes_version
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["t3.medium"]

  scaling_config {
    min_size     = 2
    desired_size = 2
    max_size     = 3
  }

  launch_template {
    id      = aws_launch_template.workers.id
    version = aws_launch_template.workers.latest_version
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_route.private_internet,
    aws_route_table_association.private,
    aws_iam_role_policy_attachment.workers,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.network["kube-proxy"],
  ]
}
