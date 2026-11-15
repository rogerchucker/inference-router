variable "apply_approval" {
  description = "Reviewed Dev plan run ID, binary SHA-256, RFC 3339 expiry and scoped IAM statements for the change. Omit to close apply access."
  type = object({
    run_id      = string
    plan_sha256 = string
    expires_at  = string
    write_statements = list(object({
      actions    = list(string)
      resources  = list(string)
      conditions = optional(map(map(list(string))), {})
    }))
  })
  default = null

  validation {
    condition = var.apply_approval == null ? true : (
      can(regex("^[1-9][0-9]*$", var.apply_approval.run_id)) &&
      can(regex("^[a-f0-9]{64}$", var.apply_approval.plan_sha256)) &&
      can(formatdate("YYYY", var.apply_approval.expires_at)) &&
      length(var.apply_approval.write_statements) > 0 &&
      alltrue([
        for statement in var.apply_approval.write_statements :
        length(statement.actions) > 0 && length(statement.resources) > 0 &&
        alltrue([for action in statement.actions : can(regex("^(ec2|eks|iam|secretsmanager):[A-Za-z][A-Za-z0-9]*$", action))]) &&
        (!contains(statement.resources, "*") || length(statement.conditions) > 0)
      ])
    )
    error_message = "Supply a run ID, lowercase SHA-256, RFC 3339 expiry and nonempty statements with explicit EC2, EKS, IAM or Secrets Manager actions and scoped resources or conditions."
  }
}

resource "aws_iam_role_policy" "approved_writes" {
  count = local.apply_enabled ? 1 : 0

  name = "approved-dev-terraform-writes"
  role = aws_iam_role.github["apply"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for statement in var.apply_approval.write_statements : {
        Effect   = "Allow"
        Action   = statement.actions
        Resource = statement.resources
        # Resource mutations also expire for sessions assumed before the cutoff.
        Condition = merge(statement.conditions, {
          DateLessThan = merge(lookup(statement.conditions, "DateLessThan", {}), {
            "aws:CurrentTime" = [var.apply_approval.expires_at]
          })
        })
      }
    ]
  })
}
