terraform {
  backend "s3" {
    bucket               = "inference-router-tfstate-922763798103-us-west-2"
    region               = "us-west-2"
    key                  = "inference-router/dev/terraform.tfstate"
    workspace_key_prefix = "inference-router/dev/workspaces"
    use_lockfile         = true
    encrypt              = true
    allowed_account_ids  = ["922763798103"]
  }
}
