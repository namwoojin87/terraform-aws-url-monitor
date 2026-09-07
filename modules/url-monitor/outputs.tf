output "lambda_function_name" {
  description = "Lambda function that executes URL checks."
  value       = aws_lambda_function.checker.function_name
}

output "state_table_name" {
  description = "DynamoDB table holding current monitor state."
  value       = aws_dynamodb_table.state.name
}

output "history_table_name" {
  description = "DynamoDB table holding seven-day check history."
  value       = aws_dynamodb_table.history.name
}

output "sns_topic_arn" {
  description = "SNS topic used for monitor notifications."
  value       = aws_sns_topic.alerts.arn
}

output "schedule_name" {
  description = "EventBridge Scheduler schedule name."
  value       = aws_scheduler_schedule.monitor.name
}

output "log_group_name" {
  description = "CloudWatch log group for the monitor Lambda."
  value       = aws_cloudwatch_log_group.checker.name
}

output "dashboard_name" {
  description = "Operations dashboard name, or null when disabled."
  value       = var.dashboard_enabled ? aws_cloudwatch_dashboard.operations[0].dashboard_name : null
}

output "dashboard_url" {
  description = "Authenticated AWS console dashboard link, or null when disabled."
  value       = var.dashboard_enabled ? "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.operations[0].dashboard_name}" : null
}
