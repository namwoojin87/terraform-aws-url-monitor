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

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
      id     = "11111111-1111-1111-1111-111111111111"
      key_id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::url-monitor-tfstate-123456789012"
      id  = "url-monitor-tfstate-123456789012"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/url-monitor-github"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/url-monitor"
    }
  }
}

variables {
  github_owner         = "portfolio-owner"
  github_owner_id      = "123456789"
  github_repository    = "terraform-aws-url-monitor"
  github_repository_id = "987654321"
  alert_email          = "alerts@example.com"
}

override_resource {
  target          = aws_kms_key.alerts
  override_during = plan
  values = {
    arn    = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
    id     = "11111111-1111-1111-1111-111111111111"
    key_id = "11111111-1111-1111-1111-111111111111"
  }
}

run "keeps_single_rotating_alert_key" {
  command = plan

  assert {
    condition     = aws_kms_key.alerts.enable_key_rotation && aws_kms_key.alerts.rotation_period_in_days == 365 && aws_kms_key.alerts.deletion_window_in_days == 30 && !aws_kms_key.alerts.multi_region && aws_kms_key.alerts.key_usage == "ENCRYPT_DECRYPT" && aws_kms_key.alerts.customer_master_key_spec == "SYMMETRIC_DEFAULT"
    error_message = "The single SNS key must retain the approved rotation and deletion boundaries."
  }

  assert {
    condition     = aws_kms_alias.alerts.name == "alias/url-monitor-alerts" && aws_kms_alias.alerts.target_key_id == aws_kms_key.alerts.key_id
    error_message = "Runtime must resolve the one bootstrap-owned key."
  }

  assert {
    condition     = output.alerts_kms_key_arn == "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
    error_message = "Bootstrap must expose the exact alert key ARN without exposing bootstrap state to runtime."
  }
}

run "constrains_alert_key_publishers" {
  command = plan

  assert {
    condition = (
      toset(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "EnableAccountIAMPermissions"]).actions) == toset(["kms:*"]) &&
      toset(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "EnableAccountIAMPermissions"]).resources) == toset(["*"]) &&
      one(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "EnableAccountIAMPermissions"]).principals).type == "AWS" &&
      toset(one(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "EnableAccountIAMPermissions"]).principals).identifiers) == toset(["arn:aws:iam::123456789012:root"])
    )
    error_message = "The key policy must delegate account IAM permissions only through the account root principal."
  }

  assert {
    condition = (
      toset(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).actions) == toset(["kms:GenerateDataKey*", "kms:Decrypt"]) &&
      toset(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).resources) == toset(["*"]) &&
      one(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).principals).type == "Service" &&
      toset(one(one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).principals).identifiers) == toset(["cloudwatch.amazonaws.com"]) &&
      anytrue([for condition in one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).condition : condition.test == "StringEquals" && condition.variable == "aws:SourceAccount" && toset(condition.values) == toset(["123456789012"])]) &&
      anytrue([for condition in one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).condition : condition.test == "ArnEquals" && condition.variable == "aws:SourceArn" && toset(condition.values) == toset(["arn:aws:cloudwatch:ap-northeast-2:123456789012:alarm:url-monitor-lambda-errors"])]) &&
      anytrue([for condition in one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).condition : condition.test == "StringEquals" && condition.variable == "kms:EncryptionContext:aws:sns:topicArn" && toset(condition.values) == toset(["arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts"])]) &&
      alltrue([for condition in one([for statement in data.aws_iam_policy_document.alerts_key.statement : statement if statement.sid == "AllowProjectAlarmEncryption"]).condition : condition.variable != "kms:ViaService"])
    )
    error_message = "CloudWatch key use must be limited to the exact alarm, account, topic context, and crypto actions without ViaService."
  }
}

run "limits_deploy_to_describing_the_alert_key" {
  command = plan

  assert {
    condition = (
      length([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "DescribeProjectAlertKey"]) == 1 &&
      toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "DescribeProjectAlertKey"]).actions) == toset(["kms:DescribeKey"]) &&
      toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "DescribeProjectAlertKey"]).resources) == toset(["arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"]) &&
      length([for statement in data.aws_iam_policy_document.deploy.statement : statement if anytrue([for action in statement.actions : startswith(lower(action), "kms:")])]) == 1
    )
    error_message = "Deploy may only describe the exact alert key and must receive no KMS administration actions."
  }
}
