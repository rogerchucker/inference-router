module "eks" {
  source = "../../modules/eks-control-plane"

  cluster_name       = "inference-router-staging"
  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = aws_iam_role.control_plane.arn
  private_subnet_ids = toset([for subnet in aws_subnet.private : subnet.id])

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = {
    Project     = "inference-router"
    Environment = "staging"
  }
}

output "cluster_name" {
  description = "Name of the staging cluster."
  value       = module.eks.cluster_name
}
