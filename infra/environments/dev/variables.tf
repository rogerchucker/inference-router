variable "aws_region" {
  description = "AWS region for the dev cluster."
  type        = string
  nullable    = false
}

variable "aws_account_id" {
  description = "AWS account that owns dev."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "The dev AWS account ID must contain 12 digits."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version, such as 1.35."
  type        = string
  nullable    = false
}

variable "cluster_admin_principal_arn" {
  description = "Existing IAM principal that can assume the short-lived dev cluster admin role."
  type        = string
  nullable    = false
}

variable "session_host_ami_id" {
  description = "Pinned Amazon Linux 2023 arm64 AMI ID in the dev region."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^ami-[0-9a-f]{17}$", var.session_host_ami_id))
    error_message = "Supply a regional AMI ID with 17 hexadecimal digits."
  }
}

variable "vpc_cidr" {
  description = "Dev VPC IPv4 CIDR. Use a nonoverlapping /16."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16")
    error_message = "Supply an IPv4 /16 CIDR for Dev."
  }
}
