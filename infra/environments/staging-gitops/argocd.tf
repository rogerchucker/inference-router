resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = local.argo_helm_repo
  chart      = "argo-cd"
  version    = "10.18.0"

  atomic  = true
  timeout = 600

  values = [file("${path.module}/argocd.values.yaml")]
}

resource "helm_release" "staging_application" {
  name       = "staging-router"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = local.argo_helm_repo
  chart      = "argocd-apps"
  version    = "2.0.8"

  atomic  = true
  timeout = 300

  values = [yamlencode({
    projects = {
      staging-router = {
        namespace   = local.argocd_ns
        description = "Inference router on staging EKS"
        sourceRepos = [local.repo_url]
        destinations = [{
          namespace = local.router_ns
          server    = "https://kubernetes.default.svc"
        }]
        clusterResourceWhitelist = []
        namespaceResourceWhitelist = [
          { group = "", kind = "ConfigMap" },
          { group = "", kind = "Service" },
          { group = "apps", kind = "Deployment" },
          { group = "external-secrets.io", kind = "ExternalSecret" },
          { group = "external-secrets.io", kind = "SecretStore" },
        ]
      }
    }
    applications = {
      inference-router-staging = {
        namespace = local.argocd_ns
        project   = "staging-router"
        source = {
          repoURL        = local.repo_url
          targetRevision = "main"
          path           = "deploy/overlays/staging"
        }
        destination = {
          namespace = local.router_ns
          server    = "https://kubernetes.default.svc"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.external_secrets,
    kubernetes_namespace_v1.router,
    kubernetes_secret_v1.argocd_repository,
  ]
}
