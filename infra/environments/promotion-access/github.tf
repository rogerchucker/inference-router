resource "github_repository_environment" "verify" {
  for_each = local.environments

  repository  = local.repository
  environment = "${each.key}-verify"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  for_each = github_repository_environment.verify

  repository     = each.value.repository
  environment    = each.value.environment
  branch_pattern = "main"
}

locals {
  variables = {
    for entry in flatten([
      for env in local.environments : [
        for name, value in {
          AWS_REGION            = local.region
          VERIFICATION_ROLE_ARN = aws_iam_role.verify[env].arn
          EKS_CLUSTER           = data.terraform_remote_state.cluster[env].outputs.cluster_name
          EKS_SESSION_HOST_ID   = data.terraform_remote_state.cluster[env].outputs.session_host_instance_id
        } : { environment = env, name = name, value = value }
      ]
    ]) : "${entry.environment}.${entry.name}" => entry
  }
}

resource "github_actions_environment_variable" "verify" {
  for_each = local.variables

  repository    = local.repository
  environment   = github_repository_environment.verify[each.value.environment].environment
  variable_name = each.value.name
  value         = each.value.value
}

variable "promotion_enabled" {
  description = "Enable GitHub Actions promotion after both EKS environments and provider secrets are ready."
  type        = bool
  default     = false
  nullable    = false
}

resource "github_actions_variable" "promotion_enabled" {
  repository    = local.repository
  variable_name = "PROMOTION_ENABLED"
  value         = tostring(var.promotion_enabled)

  depends_on = [
    aws_eks_access_entry.verify,
    aws_iam_role_policy.verify,
    github_actions_environment_variable.verify,
    module.dev_rbac,
    module.staging_rbac,
  ]
}
