terraform {
  required_version = "~> 1.17.0"

  backend "s3" {
    bucket              = "inference-router-tfstate-922763798103-us-west-2"
    key                 = "inference-router/shared/promotion-access.tfstate"
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}

locals {
  account    = "922763798103"
  region     = "us-west-2"
  bucket     = "inference-router-tfstate-${local.account}-${local.region}"
  owner      = "rogerchucker"
  repository = "inference-router"
  oidc_host  = "token.actions.githubusercontent.com"
  # Match the immutable owner and repository IDs in staging bootstrap.
  oidc_repository = "${local.owner}@335912/${local.repository}@1457504171"
  environments    = toset(["dev", "staging"])
  groups          = { for env in local.environments : env => "inference-router-${env}-verification" }
  cluster_arns = {
    for env in local.environments : env => "arn:aws:eks:${local.region}:${local.account}:cluster/${local.repository}-${env}"
  }
}

variable "dev_kubeconfig_path" {
  description = "Administrator kubeconfig for the Dev private EKS API through its authenticated tunnel, with the Dev cluster ARN as its context name."
  type        = string
  ephemeral   = true
}

variable "staging_kubeconfig_path" {
  description = "Administrator kubeconfig for the Stage private EKS API through its authenticated tunnel, with the Stage cluster ARN as its context name."
  type        = string
  ephemeral   = true
}

provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account]
  default_tags {
    tags = { Project = "inference-router" }
  }
}

provider "github" {
  owner = local.owner
}

provider "kubernetes" {
  alias          = "dev"
  config_path    = var.dev_kubeconfig_path
  config_context = local.cluster_arns["dev"]
}

provider "kubernetes" {
  alias          = "staging"
  config_path    = var.staging_kubeconfig_path
  config_context = local.cluster_arns["staging"]
}

data "terraform_remote_state" "cluster" {
  for_each = local.environments
  backend  = "s3"
  config = {
    bucket              = local.bucket
    key                 = "inference-router/${each.key}/terraform.tfstate"
    region              = local.region
    allowed_account_ids = [local.account]
  }
}

module "dev_rbac" {
  source       = "../../modules/release-verifier-rbac"
  providers    = { kubernetes = kubernetes.dev }
  namespace    = data.terraform_remote_state.cluster["dev"].outputs.cluster_name
  access_group = local.groups["dev"]
}

module "staging_rbac" {
  source       = "../../modules/release-verifier-rbac"
  providers    = { kubernetes = kubernetes.staging }
  namespace    = data.terraform_remote_state.cluster["staging"].outputs.cluster_name
  access_group = local.groups["staging"]
}
