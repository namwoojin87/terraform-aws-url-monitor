resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.project_name}-scheduler-dlq"
  fifo_queue                = false
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.project_name}-lambda-dlq"
  fifo_queue                = false
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_lambda_function_event_invoke_config" "checker" {
  function_name                = aws_lambda_function.checker.function_name
  maximum_event_age_in_seconds = 300
  maximum_retry_attempts       = 0
}
