mock_provider "aws" {
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
    arn = "arn:aws:sns:us-east-1:123456789012:url-monitor-alerts"
  }
}

variables {
  project_name = "url-monitor"
  alert_email  = "alerts@example.com"
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
    condition     = aws_lambda_function.checker.memory_size == 128 && aws_lambda_function.checker.reserved_concurrent_executions == 1
    error_message = "Lambda must retain 128 MB memory and reserved concurrency of one."
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
    condition     = data.aws_caller_identity.current.account_id == "123456789012"
    error_message = "Scheduler trust policy must derive its source account from the AWS provider."
  }

  assert {
    condition     = output.lambda_function_name == "url-monitor-checker" && output.state_table_name == "url-monitor-state" && output.sns_topic_arn == "arn:aws:sns:us-east-1:123456789012:url-monitor-alerts" && output.schedule_name == "url-monitor-checks" && output.log_group_name == "/aws/lambda/url-monitor-checker"
    error_message = "Module outputs must expose the Lambda, state table, topic, schedule, and log group."
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
