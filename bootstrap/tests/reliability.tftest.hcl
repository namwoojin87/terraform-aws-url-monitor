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

run "grants_project_reliability_management" {
  command = plan

  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "ManageProjectPointInTimeRecovery"]).actions) == toset(["dynamodb:UpdateContinuousBackups"]) && toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "ManageProjectPointInTimeRecovery"]).resources) == toset(["arn:aws:dynamodb:ap-northeast-2:123456789012:table/url-monitor-state", "arn:aws:dynamodb:ap-northeast-2:123456789012:table/url-monitor-history"])
    error_message = "Deploy may update continuous backups only for the two monitor tables."
  }

  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "ManageProjectAsyncFailurePolicy"]).actions) == toset(["lambda:GetFunctionEventInvokeConfig", "lambda:PutFunctionEventInvokeConfig", "lambda:DeleteFunctionEventInvokeConfig"]) && toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "ManageProjectAsyncFailurePolicy"]).resources) == toset(["arn:aws:lambda:ap-northeast-2:123456789012:function:url-monitor-checker"])
    error_message = "Deploy may manage async failure settings only for the checker function."
  }

  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "ManageProjectFailureQueues"]).actions) == toset(["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:GetQueueAttributes", "sqs:ListQueueTags", "sqs:SetQueueAttributes", "sqs:TagQueue", "sqs:UntagQueue"]) && toset(one([for statement in data.aws_iam_policy_document.deploy.statement : statement if statement.sid == "ManageProjectFailureQueues"]).resources) == toset(["arn:aws:sqs:ap-northeast-2:123456789012:url-monitor-scheduler-dlq", "arn:aws:sqs:ap-northeast-2:123456789012:url-monitor-lambda-dlq"])
    error_message = "Deploy may manage only the two project failure queues with the approved actions."
  }
}
