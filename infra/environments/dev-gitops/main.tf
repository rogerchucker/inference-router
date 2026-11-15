terraform {
  required_version = "~> 1.17.0"

  backend "s3" {
    bucket              = "inference-router-tfstate-922763798103-us-west-2"
    key                 = "inference-router/dev/gitops.tfstate"
    region              = "us-west-2"
    use_lockfile        = true
    encrypt             = true
    allowed_account_ids = ["922763798103"]
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}

locals {
  account        = "922763798103"
  region         = "us-west-2"
  cluster        = "inference-router-dev"
  cluster_arn    = "arn:aws:eks:${local.region}:${local.account}:cluster/${local.cluster}"
  owner          = "rogerchucker"
  repository     = "inference-router"
  repo_url       = "ssh://git@github.com/${local.owner}/${local.repository}.git"
  argocd_ns      = "argocd"
  argo_project   = "dev-router"
  router_ns      = "inference-router-dev"
  eso_account    = "dev-external-secrets"
  argo_helm_repo = "https://argoproj.github.io/argo-helm"
}

variable "kubeconfig_path" {
  description = "Kubeconfig for the Dev private EKS API through an authenticated tunnel. Keep the default EKS ARN as the context name."
  type        = string
  ephemeral   = true
}

variable "repository_ssh_public_key" {
  description = "Public half of the dedicated, read-only GitHub repository deploy key for Dev."
  type        = string
}

variable "repository_ssh_private_key" {
  description = "Private half of the dedicated GitHub deploy key for Dev. Supply it for plan and apply."
  type        = string
  sensitive   = true
  ephemeral   = true
}

provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account]
  default_tags {
    tags = {
      Project     = "inference-router"
      Environment = "dev"
    }
  }
}

provider "github" {
  owner = local.owner
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = local.cluster_arn
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = local.cluster_arn
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = local.argocd_ns
  }
}

resource "kubernetes_namespace_v1" "router" {
  metadata {
    name = local.router_ns
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "github_repository_deploy_key" "argocd" {
  repository = local.repository
  title      = "inference-router-dev-argocd"
  key        = var.repository_ssh_public_key
  read_only  = true
}

resource "kubernetes_secret_v1" "argocd_repository" {
  metadata {
    name      = "inference-router-repository"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }

  type = "Opaque"
  data_wo = {
    type          = "git"
    url           = local.repo_url
    project       = local.argo_project
    sshPrivateKey = var.repository_ssh_private_key
  }
  data_wo_revision = 1

  depends_on = [github_repository_deploy_key.argocd]
}
