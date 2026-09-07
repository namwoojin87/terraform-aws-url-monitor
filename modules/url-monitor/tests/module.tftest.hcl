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

run "dashboard_disabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_dashboard.operations) == 0 && output.dashboard_name == null
    error_message = "The reusable module must not create a dashboard unless opted in."
  }
}

run "dashboard_uses_scoped_existing_metrics_and_preserves_paused_schedule" {
  command = plan

  variables {
    dashboard_enabled = true
    schedule_enabled  = false
  }

  assert {
    condition     = aws_cloudwatch_dashboard.operations[0].dashboard_name == "url-monitor-operations" && output.dashboard_name == "url-monitor-operations"
    error_message = "Enabling the dashboard must expose the exact project dashboard name."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.state == "DISABLED"
    error_message = "Creating a dashboard must not enable URL checks."
  }

  assert {
    condition = alltrue([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      contains(["text", "metric"], widget.type)
    ])
    error_message = "Only text and existing metric widgets are allowed; no log queries or custom widgets."
  }

  assert {
    condition = alltrue(flatten([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      [for metric in widget.properties.metrics : contains(["AWS/Lambda", "AWS/SNS", "AWS/DynamoDB", "AWS/Scheduler", "AWS/SQS"], metric[0])]
      if widget.type == "metric"
    ]))
    error_message = "Every metric must use an existing AWS service namespace; no custom metrics or expressions."
  }

  assert {
    condition = alltrue([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      widget.properties.region == "ap-northeast-2" && widget.properties.period == 300
      if widget.type == "metric"
    ])
    error_message = "Every metric must use the deployed region and a five-minute aggregation."
  }

  assert {
    condition = contains(flatten([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      [for metric in widget.properties.metrics : join("/", slice(metric, 0, 4))]
      if widget.type == "metric"
    ]), "AWS/Lambda/Invocations/FunctionName/url-monitor-checker")
    error_message = "The invocation graph must target this project's Lambda rather than account-wide metrics."
  }

  assert {
    condition = contains(flatten([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      [for metric in widget.properties.metrics : join("/", slice(metric, 0, 4))]
      if widget.type == "metric"
    ]), "AWS/SNS/NumberOfNotificationsDelivered/TopicName/url-monitor-alerts")
    error_message = "The delivery graph must target this project's SNS topic."
  }

  assert {
    condition = alltrue([
      for table in ["url-monitor-state", "url-monitor-history"] :
      contains(flatten([
        for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
        [for metric in widget.properties.metrics : join("/", slice(metric, 0, 4))]
        if widget.type == "metric"
      ]), "AWS/DynamoDB/ConsumedWriteCapacityUnits/TableName/${table}")
    ])
    error_message = "Both current-state and history tables must appear in the write-capacity graph."
  }

  assert {
    condition = length(flatten([
      for widget in jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets :
      [for metric in widget.properties.metrics : metric[1]] if widget.type == "metric"
    ])) <= 20
    error_message = "The dashboard must remain a small bounded set of existing metrics."
  }

  assert {
    condition     = strcontains(jsondecode(aws_cloudwatch_dashboard.operations[0].dashboard_body).widgets[0].properties.markdown, "DISABLED") && strcontains(output.dashboard_url, "ap-northeast-2")
    error_message = "Operators must see the configured pause state and a link for the correct region."
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
  target          = aws_dynamodb_table.history
  override_during = plan
  values = {
    arn = "arn:aws:dynamodb:ap-northeast-2:123456789012:table/url-monitor-history"
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
  target          = aws_cloudwatch_log_group.checker
  override_during = plan
  values = {
    arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/lambda/url-monitor-checker"
  }
}

variables {
  project_name       = "url-monitor"
  alert_email        = "alerts@example.com"
  alerts_kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
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

run "plans_low_cost_runtime" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.state.billing_mode == "PAY_PER_REQUEST"
    error_message = "DynamoDB must use on-demand capacity."
  }

  assert {
    condition     = aws_dynamodb_table.history.billing_mode == "PAY_PER_REQUEST" && aws_dynamodb_table.history.hash_key == "monitor_id" && aws_dynamodb_table.history.range_key == "checked_at"
    error_message = "History must use on-demand capacity with monitor and timestamp keys."
  }

  assert {
    condition     = aws_dynamodb_table.history.ttl[0].attribute_name == "expires_at" && aws_dynamodb_table.history.ttl[0].enabled
    error_message = "History must expire through the enabled expires_at TTL."
  }

  assert {
    condition     = aws_lambda_function.checker.timeout == 30
    error_message = "Lambda timeout must remain 30 seconds."
  }

  assert {
    condition     = aws_cloudwatch_log_group.checker.retention_in_days == 7
    error_message = "Log retention must default to seven days."
  }
}

run "wires_runtime_delivery_and_outputs" {
  command = plan

  assert {
    condition     = aws_lambda_function.checker.runtime == "python3.13"
    error_message = "Lambda runtime must remain Python 3.13."
  }

  assert {
    condition     = aws_lambda_function.checker.handler == "url_monitor.handler.lambda_handler"
    error_message = "Lambda handler must remain the packaged URL monitor handler."
  }

  assert {
    condition     = aws_lambda_function.checker.memory_size == 128
    error_message = "Lambda must retain 128 MB memory without a per-function concurrency reservation."
  }

  assert {
    condition     = aws_dynamodb_table.state.hash_key == "monitor_id" && aws_dynamodb_table.state.ttl[0].attribute_name == "expires_at" && aws_dynamodb_table.state.ttl[0].enabled
    error_message = "State table must retain its monitor ID key and expiration TTL."
  }

  assert {
    condition     = aws_sns_topic_subscription.email.topic_arn == aws_sns_topic.alerts.arn && contains(tolist(aws_cloudwatch_metric_alarm.lambda_errors.alarm_actions), aws_sns_topic.alerts.arn)
    error_message = "Subscription and Lambda error alarm must both use the alert topic."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.target[0].role_arn == aws_iam_role.scheduler.arn && aws_iam_role_policy.scheduler.role == aws_iam_role.scheduler.id && aws_iam_role_policy.lambda.role == aws_iam_role.lambda.id
    error_message = "Scheduler and Lambda policies must attach to their corresponding roles."
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.monitor.target[0].input).targets.demo.timeout_seconds == 5 && jsondecode(aws_scheduler_schedule.monitor.target[0].input).targets.demo.url == "https://example.com"
    error_message = "Scheduler payload must supply targets using the Lambda contract."
  }

  assert {
    condition     = aws_lambda_function.checker.environment[0].variables.HISTORY_TABLE_NAME == aws_dynamodb_table.history.name
    error_message = "Lambda must receive the history table name."
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.monitor.target[0].input).history_ttl_days == 7
    error_message = "Scheduler payload must retain history for seven days."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.state == "ENABLED"
    error_message = "Reusable module schedule defaults to enabled."
  }

  assert {
    condition = length([
      for statement in data.aws_iam_policy_document.lambda.statement : statement
      if contains(statement.actions, "dynamodb:PutItem") && contains(statement.resources, aws_dynamodb_table.history.arn)
    ]) == 1
    error_message = "Lambda must receive PutItem access to the history table."
  }

  assert {
    condition     = data.aws_caller_identity.current.account_id == "123456789012"
    error_message = "Scheduler trust policy must derive its source account from the AWS provider."
  }

  assert {
    condition     = output.lambda_function_name == "url-monitor-checker" && output.state_table_name == "url-monitor-state" && output.sns_topic_arn == "arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts" && output.schedule_name == "url-monitor-checks" && output.log_group_name == "/aws/lambda/url-monitor-checker"
    error_message = "Module outputs must expose the Lambda, state table, topic, schedule, and log group."
  }

  assert {
    condition     = output.history_table_name == "url-monitor-history"
    error_message = "Module must expose the history table name."
  }
}

run "rejects_six_targets" {
  command = plan

  variables {
    monitor_targets = {
      one   = { url = "https://example.com/1" }
      two   = { url = "https://example.com/2" }
      three = { url = "https://example.com/3" }
      four  = { url = "https://example.com/4" }
      five  = { url = "https://example.com/5" }
      six   = { url = "https://example.com/6" }
    }
  }

  expect_failures = [var.monitor_targets]
}
