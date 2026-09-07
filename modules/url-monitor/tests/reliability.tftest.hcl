mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "ap-northeast-2"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

override_resource {
  target          = aws_iam_role.lambda
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/url-monitor-lambda"
    id  = "url-monitor-lambda"
  }
}

override_resource {
  target          = aws_iam_role.scheduler
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/url-monitor-scheduler"
    id  = "url-monitor-scheduler"
  }
}

override_resource {
  target          = aws_sns_topic.alerts
  override_during = plan
  values = {
    arn = "arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts"
  }
}

override_resource {
  target          = aws_dynamodb_table.state
  override_during = plan
  values = {
    arn = "arn:aws:dynamodb:ap-northeast-2:123456789012:table/url-monitor-state"
  }
}

override_resource {
  target          = aws_dynamodb_table.history
  override_during = plan
  values = {
    arn = "arn:aws:dynamodb:ap-northeast-2:123456789012:table/url-monitor-history"
  }
}

override_resource {
  target          = aws_cloudwatch_log_group.checker
  override_during = plan
  values = {
    arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/lambda/url-monitor-checker"
  }
}

override_resource {
  target          = aws_sqs_queue.scheduler_dlq
  override_during = plan
  values = {
    arn = "arn:aws:sqs:ap-northeast-2:123456789012:url-monitor-scheduler-dlq"
    url = "https://sqs.ap-northeast-2.amazonaws.com/123456789012/url-monitor-scheduler-dlq"
  }
}

override_resource {
  target          = aws_sqs_queue.lambda_dlq
  override_during = plan
  values = {
    arn = "arn:aws:sqs:ap-northeast-2:123456789012:url-monitor-lambda-dlq"
    url = "https://sqs.ap-northeast-2.amazonaws.com/123456789012/url-monitor-lambda-dlq"
  }
}

variables {
  project_name     = "url-monitor"
  alert_email      = "alerts@example.com"
  schedule_enabled = false
  monitor_targets = {
    demo = {
      url               = "https://example.com"
      expected_statuses = [200]
      timeout_seconds   = 5
    }
  }
  lambda_package = {
    filename         = "fixture.zip"
    source_code_hash = "ZmFrZS1oYXNo"
  }
}

run "separates_failure_stages" {
  command = plan

  assert {
    condition     = aws_sqs_queue.scheduler_dlq.name == "url-monitor-scheduler-dlq" && aws_sqs_queue.lambda_dlq.name == "url-monitor-lambda-dlq"
    error_message = "Delivery-stage and execution-stage failures need distinct queues."
  }

  assert {
    condition     = alltrue([for q in [aws_sqs_queue.scheduler_dlq, aws_sqs_queue.lambda_dlq] : q.sqs_managed_sse_enabled && !q.fifo_queue && q.message_retention_seconds == 1209600])
    error_message = "DLQs must be Standard, SSE-SQS encrypted and retained for 14 days."
  }

  assert {
    condition     = one(aws_lambda_function.checker.dead_letter_config).target_arn == aws_sqs_queue.lambda_dlq.arn && one(one(aws_scheduler_schedule.monitor.target).dead_letter_config).arn == aws_sqs_queue.scheduler_dlq.arn
    error_message = "Each stage must send to its own DLQ."
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.checker.maximum_retry_attempts == 0 && aws_lambda_function_event_invoke_config.checker.maximum_event_age_in_seconds == 300 && aws_lambda_function_event_invoke_config.checker.function_name == aws_lambda_function.checker.function_name
    error_message = "Unqualified async execution must use age 300 and zero code-error retries."
  }

  assert {
    condition     = one(aws_dynamodb_table.state.point_in_time_recovery).enabled && one(aws_dynamodb_table.history.point_in_time_recovery).enabled && one(aws_lambda_function.checker.tracing_config).mode == "Active"
    error_message = "Both tables need PITR and Lambda needs Active tracing."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.state == "DISABLED" && one(one(aws_scheduler_schedule.monitor.target).retry_policy).maximum_event_age_in_seconds == 300 && one(one(aws_scheduler_schedule.monitor.target).retry_policy).maximum_retry_attempts == 1
    error_message = "Reliability wiring must preserve the paused schedule and Scheduler retry policy."
  }

  assert {
    condition     = output.scheduler_dlq_url == "https://sqs.ap-northeast-2.amazonaws.com/123456789012/url-monitor-scheduler-dlq" && output.lambda_dlq_url == "https://sqs.ap-northeast-2.amazonaws.com/123456789012/url-monitor-lambda-dlq"
    error_message = "Both failure-stage queue URLs must be exposed."
  }
}

run "grants_runtime_failure_permissions" {
  command = plan

  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.lambda.statement : statement if statement.sid == "SendExecutionFailures"]).actions) == toset(["sqs:SendMessage"]) && toset(one([for statement in data.aws_iam_policy_document.lambda.statement : statement if statement.sid == "SendExecutionFailures"]).resources) == toset(["arn:aws:sqs:ap-northeast-2:123456789012:url-monitor-lambda-dlq"])
    error_message = "Lambda may send execution failures only to its own queue."
  }

  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.lambda.statement : statement if statement.sid == "WriteSampledTraces"]).actions) == toset(["xray:PutTraceSegments", "xray:PutTelemetryRecords"]) && toset(one([for statement in data.aws_iam_policy_document.lambda.statement : statement if statement.sid == "WriteSampledTraces"]).resources) == toset(["*"])
    error_message = "Lambda tracing permissions must contain only the required X-Ray writes on star."
  }

  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.scheduler.statement : statement if statement.sid == "SendDeliveryFailures"]).actions) == toset(["sqs:SendMessage"]) && toset(one([for statement in data.aws_iam_policy_document.scheduler.statement : statement if statement.sid == "SendDeliveryFailures"]).resources) == toset(["arn:aws:sqs:ap-northeast-2:123456789012:url-monitor-scheduler-dlq"])
    error_message = "Scheduler may send delivery failures only to its own queue."
  }
}

run "displays_operational_failure_signals" {
  command = plan

  variables {
    dashboard_enabled = true
  }

  assert {
    condition = sum([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      length(widget.properties.metrics) if widget.type == "metric"
    ]) == 20
    error_message = "The dashboard must contain exactly 20 metric series."
  }

  assert {
    condition = alltrue([
      for expected in [
        ["AWS/Scheduler", "TargetErrorCount", "ScheduleGroup", "url-monitor"],
        ["AWS/Scheduler", "InvocationDroppedCount", "ScheduleGroup", "url-monitor"],
        ["AWS/Scheduler", "InvocationsSentToDeadLetterCount", "ScheduleGroup", "url-monitor"],
        ["AWS/Scheduler", "InvocationsFailedToBeSentToDeadLetterCount", "ScheduleGroup", "url-monitor"],
        ["AWS/Lambda", "DeadLetterErrors", "FunctionName", "url-monitor-checker"],
        ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "url-monitor-scheduler-dlq"],
        ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "url-monitor-lambda-dlq"],
        ] : anytrue(flatten([
          for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets : [
            for actual in widget.properties.metrics : jsonencode(actual) == jsonencode(expected)
          ] if widget.type == "metric"
      ]))
    ])
    error_message = "The dashboard must include all seven fully scoped reliability metric rows."
  }

  assert {
    condition = alltrue([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      widget.properties.region == "ap-northeast-2" && widget.properties.period == 300
      if widget.type == "metric"
    ])
    error_message = "Every reliability metric must use Seoul and a five-minute period."
  }

  assert {
    condition = one([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets : widget
      if widget.type == "metric" && anytrue([for metric in widget.properties.metrics : metric[0] == "AWS/Scheduler"])
      ]).properties.stat == "Sum" && one([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets : widget
      if widget.type == "metric" && anytrue([for metric in widget.properties.metrics : metric[0] == "AWS/Lambda" && metric[1] == "DeadLetterErrors"])
      ]).properties.stat == "Sum" && one([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets : widget
      if widget.type == "metric" && anytrue([for metric in widget.properties.metrics : metric[0] == "AWS/SQS"])
    ]).properties.stat == "Maximum"
    error_message = "Scheduler and Lambda failure metrics use Sum, while queue depth uses Maximum."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.state == "DISABLED" && one(one(aws_scheduler_schedule.monitor.target).retry_policy).maximum_event_age_in_seconds == 300 && one(one(aws_scheduler_schedule.monitor.target).retry_policy).maximum_retry_attempts == 1
    error_message = "Dashboard signals must not enable scheduling or alter delivery retry settings."
  }
}
