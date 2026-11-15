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

variable "cluster_admin_principal_arn" {
  description = "Existing IAM principal that can assume the short-lived staging cluster admin role."
  type        = string
  nullable    = false
}

variable "session_host_ami_id" {
  description = "Pinned Amazon Linux 2023 arm64 AMI ID in the staging region."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^ami-[0-9a-f]{17}$", var.session_host_ami_id))
    error_message = "Supply a regional AMI ID with 17 hexadecimal digits."
  }
}
