resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_dynamodb_table" "state" {
  name         = "${var.project_name}-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "monitor_id"

  attribute {
    name = "monitor_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "checker" {
  name              = "/aws/lambda/${var.project_name}-checker"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "checker" {
  function_name    = "${var.project_name}-checker"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "url_monitor.handler.lambda_handler"
  filename         = var.lambda_package.filename
  source_code_hash = var.lambda_package.source_code_hash
  timeout          = 30
  memory_size      = 128

  reserved_concurrent_executions = 1

  environment {
    variables = {
      STATE_TABLE_NAME = aws_dynamodb_table.state.name
      ALERT_TOPIC_ARN  = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.checker, aws_iam_role_policy.lambda]
  tags       = var.tags
}

resource "aws_scheduler_schedule_group" "monitor" {
  name = var.project_name
  tags = var.tags
}

resource "aws_scheduler_schedule" "monitor" {
  name       = "${var.project_name}-checks"
  group_name = aws_scheduler_schedule_group.monitor.name

  depends_on = [aws_iam_role_policy.scheduler]

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = var.schedule_expression

  target {
    arn      = aws_lambda_function.checker.arn
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      failure_threshold = var.failure_threshold
      state_ttl_days    = 7
      targets = {
        for name, target in var.monitor_targets : name => {
          url               = target.url
          expected_statuses = tolist(target.expected_statuses)
          timeout_seconds   = target.timeout_seconds
        }
      }
    })

    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.checker.function_name
  }

  tags = var.tags
}
