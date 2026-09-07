locals {
  alerts_topic_arn = "arn:aws:sns:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-alerts"
  alerts_alarm_arn = "arn:aws:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-lambda-errors"
}

data "aws_iam_policy_document" "lambda_alerts_encryption" {
  statement {
    sid       = "PublishEncryptedAlerts"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [var.alerts_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sns.${data.aws_region.current.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = [local.alerts_topic_arn]
    }
  }
}

resource "aws_iam_role_policy" "lambda_alerts_encryption" {
  name   = "${var.project_name}-encrypted-alerts"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_alerts_encryption.json
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowProjectAlarmPublish"
    actions   = ["sns:Publish"]
    resources = [local.alerts_topic_arn]

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
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
