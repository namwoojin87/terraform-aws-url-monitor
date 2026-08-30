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

run "plans_safe_bootstrap" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket versioning must be enabled."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls
    error_message = "State bucket public ACLs must be blocked."
  }

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "5"
    error_message = "Monthly budget must remain USD 5."
  }
}

run "keeps_bootstrap_security_contract" {
  command = apply

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "State bucket encryption must use AES256."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.state.rule[0].noncurrent_version_expiration[0].noncurrent_days == 90
    error_message = "Noncurrent state versions must expire after 90 days."
  }

  assert {
    condition     = alltrue([aws_s3_bucket_public_access_block.state.block_public_acls, aws_s3_bucket_public_access_block.state.block_public_policy, aws_s3_bucket_public_access_block.state.ignore_public_acls, aws_s3_bucket_public_access_block.state.restrict_public_buckets])
    error_message = "Every S3 public-access protection must be enabled."
  }

  assert {
    condition     = aws_budgets_budget.monthly.budget_type == "COST" && aws_budgets_budget.monthly.limit_amount == "5" && aws_budgets_budget.monthly.limit_unit == "USD" && one(aws_budgets_budget.monthly.notification).threshold == 80 && one(aws_budgets_budget.monthly.notification).threshold_type == "PERCENTAGE" && one(aws_budgets_budget.monthly.notification).notification_type == "FORECASTED" && contains(one(aws_budgets_budget.monthly.notification).subscriber_email_addresses, "alerts@example.com")
    error_message = "Budget must remain a USD 5, 80-percent forecasted email budget."
  }

  assert {
    condition     = anytrue([for condition in data.aws_iam_policy_document.plan_assume.statement[0].condition : condition.variable == "token.actions.githubusercontent.com:aud" && toset(condition.values) == toset(["sts.amazonaws.com"])]) && anytrue([for condition in data.aws_iam_policy_document.plan_assume.statement[0].condition : condition.variable == "token.actions.githubusercontent.com:sub" && toset(condition.values) == toset(["repo:portfolio-owner@123456789/terraform-aws-url-monitor@987654321:ref:refs/heads/main"])])
    error_message = "Plan OIDC trust must be restricted to the GitHub STS audience and main branch."
  }

  assert {
    condition     = anytrue([for condition in data.aws_iam_policy_document.deploy_assume.statement[0].condition : condition.variable == "token.actions.githubusercontent.com:aud" && toset(condition.values) == toset(["sts.amazonaws.com"])]) && anytrue([for condition in data.aws_iam_policy_document.deploy_assume.statement[0].condition : condition.variable == "token.actions.githubusercontent.com:sub" && toset(condition.values) == toset(["repo:portfolio-owner@123456789/terraform-aws-url-monitor@987654321:environment:production"])])
    error_message = "Deploy OIDC trust must be restricted to the GitHub STS audience and production environment."
  }

  assert {
    condition     = toset(data.aws_iam_policy_document.state_access.statement[0].actions) == toset(["s3:ListBucket", "s3:ListBucketVersions"]) && anytrue([for condition in data.aws_iam_policy_document.state_access.statement[0].condition : condition.test == "StringLike" && condition.variable == "s3:prefix" && toset(condition.values) == toset(["infra/*"])])
    error_message = "GitHub roles must list only the live infrastructure state prefix."
  }

  assert {
    condition     = contains(data.aws_iam_policy_document.state_access.statement[1].resources, "arn:aws:s3:::url-monitor-tfstate-123456789012/infra/terraform.tfstate") && toset(data.aws_iam_policy_document.state_access.statement[1].actions) == toset(["s3:GetObject", "s3:PutObject"]) && contains(data.aws_iam_policy_document.state_access.statement[2].resources, "arn:aws:s3:::url-monitor-tfstate-123456789012/infra/terraform.tfstate.tflock") && toset(data.aws_iam_policy_document.state_access.statement[2].actions) == toset(["s3:GetObject", "s3:PutObject", "s3:DeleteObject"])
    error_message = "GitHub state access must be limited to the live state object and lock file."
  }

  assert {
    condition     = toset(data.aws_iam_policy_document.github_state_boundary.statement[1].actions) == toset(["s3:ListBucket", "s3:ListBucketVersions"]) && anytrue([for condition in data.aws_iam_policy_document.github_state_boundary.statement[1].condition : condition.test == "Null" && condition.variable == "s3:prefix" && toset(condition.values) == toset(["true"])]) && toset(data.aws_iam_policy_document.github_state_boundary.statement[2].actions) == toset(["s3:ListBucket", "s3:ListBucketVersions"]) && anytrue([for condition in data.aws_iam_policy_document.github_state_boundary.statement[2].condition : condition.test == "StringNotLike" && condition.variable == "s3:prefix" && toset(condition.values) == toset(["infra/*"])])
    error_message = "Bucket policy must deny root, bootstrap, and other non-infrastructure listings."
  }

  assert {
    condition     = toset(data.aws_iam_policy_document.github_state_boundary.statement[0].actions) == toset(["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject"]) && contains(data.aws_iam_policy_document.github_state_boundary.statement[0].resources, "arn:aws:s3:::url-monitor-tfstate-123456789012/bootstrap/*")
    error_message = "Bucket policy must deny GitHub roles access to bootstrap state objects."
  }

  assert {
    condition     = contains(data.aws_iam_policy_document.deploy.statement[0].resources, "arn:aws:lambda:ap-northeast-2:123456789012:function:url-monitor-*") && contains(data.aws_iam_policy_document.deploy.statement[1].resources, "arn:aws:dynamodb:ap-northeast-2:123456789012:table/url-monitor-*") && contains(data.aws_iam_policy_document.deploy.statement[2].resources, "arn:aws:sns:ap-northeast-2:123456789012:url-monitor-*") && contains(data.aws_iam_policy_document.deploy.statement[3].resources, "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/lambda/url-monitor-*") && contains(data.aws_iam_policy_document.deploy.statement[4].resources, "arn:aws:scheduler:ap-northeast-2:123456789012:schedule/url-monitor/url-monitor-*") && contains(data.aws_iam_policy_document.deploy.statement[4].resources, "arn:aws:scheduler:ap-northeast-2:123456789012:schedule-group/url-monitor") && contains(data.aws_iam_policy_document.deploy.statement[5].resources, "arn:aws:cloudwatch:ap-northeast-2:123456789012:alarm:url-monitor-*") && contains(data.aws_iam_policy_document.deploy.statement[6].resources, "arn:aws:iam::123456789012:role/url-monitor-*")
    error_message = "Deploy permissions must be scoped to approved services, account, region, and project prefix."
  }

  assert {
    condition     = toset(data.aws_iam_policy_document.deploy.statement[7].actions) == toset(["iam:PassRole"]) && contains(data.aws_iam_policy_document.deploy.statement[7].resources, "arn:aws:iam::123456789012:role/url-monitor-*") && anytrue([for condition in data.aws_iam_policy_document.deploy.statement[7].condition : condition.variable == "iam:PassedToService" && toset(condition.values) == toset(["lambda.amazonaws.com", "scheduler.amazonaws.com"])])
    error_message = "Deploy role passing must be limited to project roles for Lambda and Scheduler."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess" && aws_iam_role_policy_attachment.plan_state.policy_arn == aws_iam_policy.state_access.arn && aws_iam_role_policy_attachment.deploy_project.policy_arn == aws_iam_policy.deploy.arn && aws_iam_role_policy_attachment.deploy_state.policy_arn == aws_iam_policy.state_access.arn
    error_message = "Plan and deploy roles must retain their required policy attachments."
  }

  assert {
    condition     = output.state_bucket_name == aws_s3_bucket.state.id && output.aws_account_id == "123456789012" && output.plan_role_arn == aws_iam_role.plan.arn && output.deploy_role_arn == aws_iam_role.deploy.arn
    error_message = "Bootstrap outputs must expose the bucket, account, and both GitHub role ARNs."
  }
}
