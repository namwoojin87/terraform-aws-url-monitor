variable "aws_region" {
  description = "AWS region for the monitor."
  type        = string
  default     = "ap-northeast-2"
}

variable "alert_email" {
  description = "Email receiving outage and recovery alerts."
  type        = string
  sensitive   = true
}

variable "schedule_enabled" {
  description = "Whether the production URL check schedule is enabled."
  type        = bool
  default     = false
}

variable "monitor_targets" {
  description = "Public endpoints passed to the monitor module."
  type = map(object({
    url               = string
    expected_statuses = optional(set(number), [200])
    timeout_seconds   = optional(number, 5)
  }))
}
