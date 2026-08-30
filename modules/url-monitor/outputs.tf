output "lambda_function_name" {
  description = "Lambda function that executes URL checks."
  value       = aws_lambda_function.checker.function_name
}

output "state_table_name" {
  description = "DynamoDB table holding current monitor state."
  value       = aws_dynamodb_table.state.name
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
