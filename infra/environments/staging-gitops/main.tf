terraform {
  required_version = "~> 1.17.0"

  backend "s3" {
    bucket              = "inference-router-tfstate-922763798103-us-west-2"
    key                 = "inference-router/staging/gitops.tfstate"
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
  cluster        = "inference-router-staging"
  owner          = "rogerchucker"
  repository     = "inference-router"
  repo_url       = "ssh://git@github.com/${local.owner}/${local.repository}.git"
  argocd_ns      = "argocd"
  router_ns      = "inference-router-staging"
  eso_account    = "staging-external-secrets"
  argo_helm_repo = "https://argoproj.github.io/argo-helm"
}

variable "kubeconfig_path" {
  description = "Kubeconfig for the staging private EKS API through an authenticated tunnel."
  type        = string
  ephemeral   = true
}

variable "repository_ssh_public_key" {
  description = "Public half of the dedicated, read-only GitHub repository deploy key."
  type        = string
}

variable "repository_ssh_private_key" {
  description = "Private half of the dedicated GitHub deploy key. Supply it for plan and apply."
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
      Environment = "staging"
    }
  }
}

provider "github" {
  owner = local.owner
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
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
  title      = "inference-router-staging-argocd"
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
    sshPrivateKey = var.repository_ssh_private_key
  }
  data_wo_revision = 1

  depends_on = [github_repository_deploy_key.argocd]
}
