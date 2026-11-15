provider "github" {
  owner = "rogerchucker"
}

resource "github_repository_environment" "staging" {
  for_each = aws_iam_role.github

  repository  = "inference-router"
  environment = "staging-${each.key}"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  for_each = github_repository_environment.staging

  repository     = each.value.repository
  environment    = each.value.environment
  branch_pattern = "main"
}

locals {
  github_environment_variables = {
    for pair in setproduct(["plan", "apply"], ["AWS_REGION", "TERRAFORM_STATE_BUCKET", "TERRAFORM_ROLE_ARN"]) :
    "${pair[0]}.${pair[1]}" => { purpose = pair[0], name = pair[1] }
  }
}

resource "github_actions_environment_variable" "staging" {
  for_each = local.github_environment_variables

  repository    = github_repository_environment.staging[each.value.purpose].repository
  environment   = github_repository_environment.staging[each.value.purpose].environment
  variable_name = each.value.name == "TERRAFORM_ROLE_ARN" ? "TERRAFORM_${upper(each.value.purpose)}_ROLE_ARN" : each.value.name
  value = {
    AWS_REGION             = local.region
    TERRAFORM_STATE_BUCKET = aws_s3_bucket.state.id
    TERRAFORM_ROLE_ARN     = aws_iam_role.github[each.value.purpose].arn
  }[each.value.name]
}

import {
  to = github_repository_environment.staging["plan"]
  id = "inference-router:staging-plan"
}

import {
  to = github_repository_environment_deployment_policy.main["plan"]
  id = "inference-router:staging-plan:66759108"
}

import {
  to = github_actions_environment_variable.staging["plan.AWS_REGION"]
  id = "inference-router:staging-plan:AWS_REGION"
}

import {
  to = github_actions_environment_variable.staging["plan.TERRAFORM_STATE_BUCKET"]
  id = "inference-router:staging-plan:TERRAFORM_STATE_BUCKET"
}

import {
  to = github_actions_environment_variable.staging["plan.TERRAFORM_ROLE_ARN"]
  id = "inference-router:staging-plan:TERRAFORM_PLAN_ROLE_ARN"
}
