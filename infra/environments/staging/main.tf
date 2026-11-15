module "eks" {
  source = "../../modules/eks-control-plane"

  cluster_name       = "inference-router-staging"
  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = var.cluster_role_arn
  private_subnet_ids = var.private_subnet_ids

  tags = {
    Project     = "inference-router"
    Environment = "staging"
  }
}

output "cluster_name" {
  description = "Name of the staging cluster."
  value       = module.eks.cluster_name
}
