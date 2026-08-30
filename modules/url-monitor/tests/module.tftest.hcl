mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
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
