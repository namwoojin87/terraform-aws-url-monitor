locals {
  alerts_topic_arn = "arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-alerts"
  alerts_alarm_arn = "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-lambda-errors"
}

data "aws_iam_policy_document" "alerts_key" {
  statement {
    sid       = "EnableAccountIAMPermissions"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowProjectAlarmEncryption"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.alerts_alarm_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = [local.alerts_topic_arn]
    }
  }
}

resource "aws_kms_key" "alerts" {
  description              = "SNS encryption for ${var.project_name} alerts"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  key_usage                = "ENCRYPT_DECRYPT"
  multi_region             = false
  enable_key_rotation      = true
  rotation_period_in_days  = 365
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.alerts_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${var.project_name}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}
