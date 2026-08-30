output "state_bucket_name" {
  description = "Versioned S3 bucket holding Terraform state."
  value       = aws_s3_bucket.state.id
}

output "aws_account_id" {
  description = "AWS account used by GitHub credential validation."
  value       = data.aws_caller_identity.current.account_id
}

output "plan_role_arn" {
  description = "Read-only GitHub OIDC role for Terraform plan."
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "Approved GitHub OIDC role for Terraform apply."
  value       = aws_iam_role.deploy.arn
}
