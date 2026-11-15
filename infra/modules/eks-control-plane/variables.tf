variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  nullable    = false
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Use a Kubernetes minor version such as 1.35."
  }
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role that EKS assumes for its control plane."
  type        = string
  nullable    = false
}

variable "private_subnet_ids" {
  description = "Private subnets in one VPC and at least two Availability Zones."
  type        = set(string)
  nullable    = false

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Supply at least two distinct subnet IDs."
  }
}

variable "tags" {
  description = "Tags for the EKS cluster."
  type        = map(string)
  default     = {}
  nullable    = false
}
