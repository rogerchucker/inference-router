terraform {
  backend "s3" {
    bucket              = "inference-router-tfstate-922763798103-us-west-2"
    key                 = "inference-router/bootstrap/terraform.tfstate"
    region              = "us-west-2"
    use_lockfile        = true
    encrypt             = true
    allowed_account_ids = ["922763798103"]
  }
}
