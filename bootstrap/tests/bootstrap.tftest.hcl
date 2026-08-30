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

variables {
  github_owner      = "portfolio-owner"
  github_repository = "terraform-aws-url-monitor"
  alert_email       = "alerts@example.com"
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
