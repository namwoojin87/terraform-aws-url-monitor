locals {
  github_plan_role_name   = "${var.project_name}-github-plan"
  github_deploy_role_name = "${var.project_name}-github-deploy"
  github_role_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.github_plan_role_name}",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.github_deploy_role_name}",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = { Name = "${var.project_name}-github" }
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["infra/*"]
    }
  }
  statement {
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "${aws_s3_bucket.state.arn}/infra/terraform.tfstate",
    ]
  }
  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.state.arn}/infra/terraform.tfstate.tflock",
    ]
  }
}

resource "aws_iam_policy" "state_access" {
  name   = "${var.project_name}-terraform-state"
  policy = data.aws_iam_policy_document.state_access.json
}

data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:production"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = local.github_plan_role_name
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "plan_state" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

resource "aws_iam_role" "deploy" {
  name               = local.github_deploy_role_name
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    actions = [
      "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction",
      "lambda:GetFunctionCodeSigningConfig", "lambda:GetPolicy", "lambda:ListTags",
      "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
      "lambda:TagResource", "lambda:UntagResource", "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration"
    ]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-*"]
  }

  statement {
    actions = [
      "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTable", "dynamodb:DescribeTimeToLive", "dynamodb:ListTagsOfResource",
      "dynamodb:TagResource", "dynamodb:UntagResource", "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive"
    ]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project_name}-*"]
  }

  statement {
    actions = [
      "sns:CreateTopic", "sns:DeleteTopic", "sns:GetSubscriptionAttributes",
      "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic", "sns:ListTagsForResource",
      "sns:SetTopicAttributes", "sns:Subscribe", "sns:TagResource", "sns:Unsubscribe",
      "sns:UntagResource"
    ]
    resources = ["arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-*"]
  }

  statement {
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
      "logs:ListTagsForResource", "logs:PutRetentionPolicy", "logs:TagResource",
      "logs:UntagResource"
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-*"]
  }

  statement {
    actions = [
      "scheduler:CreateSchedule", "scheduler:CreateScheduleGroup", "scheduler:DeleteSchedule",
      "scheduler:DeleteScheduleGroup", "scheduler:GetSchedule", "scheduler:GetScheduleGroup",
      "scheduler:ListTagsForResource", "scheduler:TagResource", "scheduler:UntagResource",
      "scheduler:UpdateSchedule"
    ]
    resources = [
      "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/${var.project_name}/${var.project_name}-*",
      "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule-group/${var.project_name}",
    ]
  }

  statement {
    actions = [
      "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
      "cloudwatch:PutMetricAlarm", "cloudwatch:TagResource", "cloudwatch:UntagResource"
    ]
    resources = ["arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-*"]
  }

  statement {
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:GetRole",
      "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies", "iam:ListRoleTags", "iam:PutRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy"
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "scheduler.amazonaws.com"]
    }
  }

  statement {
    actions = [
      "cloudwatch:DescribeAlarms",
      "dynamodb:ListTables",
      "iam:ListRoles",
      "lambda:GetAccountSettings",
      "lambda:ListFunctions",
      "logs:DescribeLogGroups",
      "scheduler:ListScheduleGroups",
      "scheduler:ListSchedules",
      "sns:ListSubscriptions",
      "sns:ListTopics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = "${var.project_name}-github-deploy"
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy_attachment" "deploy_project" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}

resource "aws_iam_role_policy_attachment" "deploy_state" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.state_access.arn
}

data "aws_iam_policy_document" "github_state_boundary" {
  statement {
    sid    = "DenyGitHubBootstrapStateObjects"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = local.github_role_arns
    }
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/bootstrap/*"]
  }

  statement {
    sid    = "DenyGitHubStateListingWithoutPrefix"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = local.github_role_arns
    }
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "Null"
      variable = "s3:prefix"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DenyGitHubNonInfraStateListing"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = local.github_role_arns
    }
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringNotLike"
      variable = "s3:prefix"
      values   = ["infra/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.github_state_boundary.json
  depends_on = [aws_iam_role.plan, aws_iam_role.deploy]
}
