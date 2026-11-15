mock_provider "aws" {}
mock_provider "github" {}

run "apply_is_closed_by_default" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.github["apply"].assume_role_policy).Statement[0].Effect == "Deny" &&
      length(aws_iam_role_policy.approved_writes) == 0 &&
      length(github_actions_environment_variable.approval) == 0
    )
    error_message = "Dev apply must start without approved writes or an authorized plan."
  }
}

run "apply_approval_limits_the_plan_and_write_window" {
  command = plan

  variables {
    apply_approval = {
      run_id      = "12345"
      plan_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      expires_at  = timeadd(timestamp(), "1h")
      write_statements = [{
        actions   = ["eks:UpdateClusterVersion"]
        resources = ["arn:aws:eks:us-west-2:922763798103:cluster/inference-router-dev"]
      }]
    }
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.github["apply"].assume_role_policy).Statement[0].Condition.DateLessThan["aws:CurrentTime"] == var.apply_approval.expires_at &&
      jsondecode(aws_iam_role_policy.approved_writes[0].policy).Statement[0].Condition.DateLessThan["aws:CurrentTime"][0] == var.apply_approval.expires_at &&
      github_actions_environment_variable.approval["TERRAFORM_APPROVED_PLAN_RUN_ID"].value == var.apply_approval.run_id &&
      github_actions_environment_variable.approval["TERRAFORM_APPROVED_PLAN_SHA256"].value == var.apply_approval.plan_sha256
    )
    error_message = "The Dev apply role and workflow settings must retain the reviewed plan and cutoff."
  }
}
