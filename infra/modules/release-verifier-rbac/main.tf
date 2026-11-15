terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "namespace" {
  description = "Namespace of the router workload and name of its Argo CD Application."
  type        = string
}

variable "access_group" {
  description = "Kubernetes group mapped by the verifier's EKS access entry."
  type        = string
}

resource "kubernetes_role_v1" "application" {
  metadata {
    name      = "inference-router-verification"
    namespace = "argocd"
  }

  rule {
    api_groups     = ["argoproj.io"]
    resources      = ["applications"]
    resource_names = [var.namespace]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_v1" "workload" {
  metadata {
    name      = "inference-router-verification"
    namespace = var.namespace
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["inference-router"]
    verbs          = ["get"]
  }

  rule {
    api_groups     = [""]
    resources      = ["services"]
    resource_names = ["inference-router"]
    verbs          = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "verify" {
  for_each = toset(["application", "workload"])
  metadata {
    name      = "inference-router-verification"
    namespace = each.key == "application" ? kubernetes_role_v1.application.metadata[0].namespace : kubernetes_role_v1.workload.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.key == "application" ? kubernetes_role_v1.application.metadata[0].name : kubernetes_role_v1.workload.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.access_group
  }
}
