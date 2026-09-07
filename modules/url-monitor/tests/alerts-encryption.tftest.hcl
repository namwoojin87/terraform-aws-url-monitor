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
  target          = aws_sns_topic.alerts
  override_during = plan
  values = {
    arn = "arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts"
  }
}

variables {
  project_name       = "url-monitor"
  alert_email        = "alerts@example.com"
  alerts_kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
  monitor_targets = {
    demo = {
      url = "https://example.com"
    }
  }
  lambda_package = {
    filename         = "fixture.zip"
    source_code_hash = "ZmFrZS1oYXNo"
  }
}

run "encrypts_alerts_for_the_lambda_publisher" {
  command = plan

  assert {
    condition     = aws_sns_topic.alerts.kms_master_key_id == "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
    error_message = "The alert topic must use the required customer-managed key ARN."
  }

  assert {
    condition     = aws_iam_role_policy.lambda_alerts_encryption.name == "url-monitor-encrypted-alerts" && aws_iam_role_policy.lambda_alerts_encryption.role == aws_iam_role.lambda.id
    error_message = "The dedicated encrypted-alert policy must attach to the Lambda role."
  }

  assert {
    condition = (
      toset(one([for statement in data.aws_iam_policy_document.lambda_alerts_encryption.statement : statement if statement.sid == "PublishEncryptedAlerts"]).actions) == toset(["kms:GenerateDataKey*", "kms:Decrypt"]) &&
      toset(one([for statement in data.aws_iam_policy_document.lambda_alerts_encryption.statement : statement if statement.sid == "PublishEncryptedAlerts"]).resources) == toset(["arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"]) &&
      anytrue([for condition in one([for statement in data.aws_iam_policy_document.lambda_alerts_encryption.statement : statement if statement.sid == "PublishEncryptedAlerts"]).condition : condition.test == "StringEquals" && condition.variable == "kms:ViaService" && toset(condition.values) == toset(["sns.ap-northeast-2.amazonaws.com"])]) &&
      anytrue([for condition in one([for statement in data.aws_iam_policy_document.lambda_alerts_encryption.statement : statement if statement.sid == "PublishEncryptedAlerts"]).condition : condition.test == "StringEquals" && condition.variable == "kms:EncryptionContext:aws:sns:topicArn" && toset(condition.values) == toset(["arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts"])])
    )
    error_message = "Lambda key use must be limited to SNS in Seoul and the exact alert topic context."
  }
}

run "allows_only_the_exact_alarm_to_publish" {
  command = plan

  assert {
    condition     = aws_sns_topic_policy.alerts.arn == aws_sns_topic.alerts.arn
    error_message = "The alert topic policy must attach to the actual alert topic."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.alerts_topic.statement) == 1 &&
      one(data.aws_iam_policy_document.alerts_topic.statement).sid == "AllowProjectAlarmPublish" &&
      toset(one(data.aws_iam_policy_document.alerts_topic.statement).actions) == toset(["sns:Publish"]) &&
      toset(one(data.aws_iam_policy_document.alerts_topic.statement).resources) == toset(["arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts"]) &&
      one(one(data.aws_iam_policy_document.alerts_topic.statement).principals).type == "Service" &&
      toset(one(one(data.aws_iam_policy_document.alerts_topic.statement).principals).identifiers) == toset(["cloudwatch.amazonaws.com"]) &&
      anytrue([for condition in one(data.aws_iam_policy_document.alerts_topic.statement).condition : condition.test == "StringEquals" && condition.variable == "aws:SourceAccount" && toset(condition.values) == toset(["123456789012"])]) &&
      anytrue([for condition in one(data.aws_iam_policy_document.alerts_topic.statement).condition : condition.test == "ArnEquals" && condition.variable == "aws:SourceArn" && toset(condition.values) == toset(["arn:aws:cloudwatch:ap-northeast-2:123456789012:alarm:url-monitor-lambda-errors"])])
    )
    error_message = "The topic policy must grant only CloudWatch for the exact account, alarm, action, and topic."
  }

  assert {
    condition     = toset(aws_cloudwatch_metric_alarm.lambda_errors.alarm_actions) == toset([aws_sns_topic.alerts.arn])
    error_message = "The exact Lambda error alarm must retain the encrypted topic action."
  }
}

run "rejects_an_alert_key_alias" {
  command = plan

  variables {
    alerts_kms_key_arn = "alias/url-monitor-alerts"
  }

  expect_failures = [var.alerts_kms_key_arn]
}
