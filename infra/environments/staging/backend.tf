terraform {
  backend "s3" {
    key                  = "inference-router/staging/terraform.tfstate"
    workspace_key_prefix = "inference-router/staging/workspaces"
    use_lockfile         = true
    encrypt              = true
    allowed_account_ids  = ["922763798103"]
  }
}
