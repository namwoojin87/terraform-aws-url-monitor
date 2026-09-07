variable "project_name" {
  description = "Prefix used for every project resource."
  type        = string
  default     = "url-monitor"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.project_name))
    error_message = "project_name must be 3-32 lowercase letters, numbers, or hyphens."
  }
}

variable "alert_email" {
  description = "Email subscribed to monitor alerts."
  type        = string
  sensitive   = true
}

variable "monitor_targets" {
  description = "Public HTTP(S) endpoints keyed by stable monitor ID."
  type = map(object({
    url               = string
    expected_statuses = optional(set(number), [200])
    timeout_seconds   = optional(number, 5)
  }))

  validation {
    condition     = length(var.monitor_targets) >= 1 && length(var.monitor_targets) <= 5
    error_message = "monitor_targets must contain one through five endpoints."
  }

  validation {
    condition = alltrue([
      for target in values(var.monitor_targets) :
      can(regex("^https?://", target.url)) &&
      length(target.expected_statuses) > 0 &&
      target.timeout_seconds >= 1 &&
      target.timeout_seconds <= 5
    ])
    error_message = "Each target needs HTTP(S), at least one expected status, and a 1-5 second timeout."
  }
}

variable "lambda_package" {
  description = "Prepared Lambda zip file and its base64 SHA-256."
  type = object({
    filename         = string
    source_code_hash = string
  })
}

variable "schedule_expression" {
  description = "EventBridge Scheduler rate expression."
  type        = string
  default     = "rate(5 minutes)"
}

variable "schedule_enabled" {
  description = "Whether scheduled URL checks are enabled."
  type        = bool
  default     = true
}

variable "failure_threshold" {
  description = "Consecutive failures required before outage notification."
  type        = number
  default     = 2

  validation {
    condition     = var.failure_threshold >= 1
    error_message = "failure_threshold must be at least one."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags added to taggable project resources."
  type        = map(string)
  default     = {}
}
