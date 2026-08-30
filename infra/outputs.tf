output "lambda_function_name" {
  description = "Lambda function that executes checks."
  value       = module.url_monitor.lambda_function_name
}

output "state_table_name" {
  description = "DynamoDB table holding current state."
  value       = module.url_monitor.state_table_name
}

output "sns_topic_arn" {
  description = "SNS topic requiring email confirmation."
  value       = module.url_monitor.sns_topic_arn
}

output "schedule_name" {
  description = "EventBridge Scheduler schedule."
  value       = module.url_monitor.schedule_name
}

output "log_group_name" {
  description = "CloudWatch log group."
  value       = module.url_monitor.log_group_name
}
