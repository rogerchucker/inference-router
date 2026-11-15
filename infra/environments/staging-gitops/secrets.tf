resource "aws_secretsmanager_secret" "router" {
  name                    = "inference-router/staging/providers"
  recovery_window_in_days = 7
}

resource "aws_iam_role" "external_secrets" {
  name = "inference-router-staging-external-secrets"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:SourceAccount"                         = local.account
          "aws:RequestTag/eks-cluster-arn"            = "arn:aws:eks:${local.region}:${local.account}:cluster/${local.cluster}"
          "aws:RequestTag/kubernetes-namespace"       = local.router_ns
          "aws:RequestTag/kubernetes-service-account" = local.eso_account
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-staging-provider-secret"
  role = aws_iam_role.external_secrets.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.router.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = local.cluster
  namespace       = kubernetes_namespace_v1.router.metadata[0].name
  service_account = local.eso_account
  role_arn        = aws_iam_role.external_secrets.arn
  depends_on      = [aws_iam_role_policy.external_secrets]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = kubernetes_namespace_v1.router.metadata[0].name
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "2.15.0"

  atomic  = true
  timeout = 600

  values = [yamlencode({
    scopedNamespace = local.router_ns
    scopedRBAC      = true
    serviceAccount  = { name = local.eso_account }
    securityContext = {
      capabilities             = { drop = ["ALL"] }
      allowPrivilegeEscalation = false
      readOnlyRootFilesystem   = true
      runAsNonRoot             = true
    }
    processClusterExternalSecret = false
    processClusterPushSecret     = false
    processClusterStore          = false
    processClusterGenerator      = false
    processPushSecret            = false
    crds = {
      createClusterExternalSecret = false
      createClusterSecretStore    = false
      createClusterGenerator      = false
      createClusterPushSecret     = false
      createPushSecret            = false
    }
  })]

  depends_on = [aws_eks_pod_identity_association.external_secrets]
}
