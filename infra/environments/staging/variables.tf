variable "aws_region" {
  description = "AWS region for the staging cluster."
  type        = string
  nullable    = false
}

variable "aws_account_id" {
  description = "AWS account that owns staging."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "The staging AWS account ID must contain 12 digits."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version, such as 1.35."
  type        = string
  nullable    = false
}
