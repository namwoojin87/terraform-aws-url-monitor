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

variable "github_repository" {
  description = "GitHub repository trusted by AWS."
  type        = string
  default     = "terraform-aws-url-monitor"
}

variable "alert_email" {
  description = "Email receiving the AWS monthly budget notification."
  type        = string
  sensitive   = true
}
