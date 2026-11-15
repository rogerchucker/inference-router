resource "github_repository_environment" "dev" {
  for_each = aws_iam_role.github

  repository  = local.github_repo
  environment = "dev-${each.key}"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  for_each = github_repository_environment.dev

  repository     = each.value.repository
  environment    = each.value.environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "role" {
  for_each = github_repository_environment.dev

  repository    = each.value.repository
  environment   = each.value.environment
  variable_name = "TERRAFORM_${upper(each.key)}_ROLE_ARN"
  value         = aws_iam_role.github[each.key].arn

  depends_on = [github_repository_environment_deployment_policy.main]
}

resource "github_actions_environment_variable" "approval" {
  for_each = local.apply_enabled ? {
    TERRAFORM_APPROVED_PLAN_RUN_ID = var.apply_approval.run_id
    TERRAFORM_APPROVED_PLAN_SHA256 = var.apply_approval.plan_sha256
  } : {}

  repository    = local.github_repo
  environment   = github_repository_environment.dev["apply"].environment
  variable_name = each.key
  value         = each.value

  depends_on = [
    aws_iam_role_policy.approved_writes,
    github_repository_environment_deployment_policy.main,
  ]
}
