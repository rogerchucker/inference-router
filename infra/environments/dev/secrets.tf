resource "aws_secretsmanager_secret" "providers" {
  name                    = "inference-router/dev/providers"
  recovery_window_in_days = 7
}
