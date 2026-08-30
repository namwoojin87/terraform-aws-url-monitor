variable "aws_region" {
  description = "AWS region for project resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project resource prefix."
  type        = string
  default     = "url-monitor"
}

variable "github_owner" {
  description = "GitHub account that owns the repository."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub account ID used in OIDC subjects."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be a numeric GitHub account ID."
  }
}

variable "github_repository" {
  description = "GitHub repository trusted by AWS."
  type        = string
  default     = "terraform-aws-url-monitor"
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID used in OIDC subjects."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be a numeric GitHub repository ID."
  }
}

variable "alert_email" {
  description = "Email receiving the AWS monthly budget notification."
  type        = string
  sensitive   = true
}
