# Bootstrap Security Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Resolve the two concrete bootstrap Checkov findings in local code without enabling paid services or accepting security exceptions.

**Architecture:** Preserve all runtime resources and the Scheduler OFF configuration. Add bounded incomplete-upload cleanup to the existing state-bucket lifecycle rule and remove only the redundant globally scoped CloudWatch alarm-read action. Existing scoped alarm reads and approved dashboard permissions remain.

**Tech Stack:** Terraform 1.16.0, AWS provider 6.62.0, Checkov 3.3.16, Python 3.12.

**Spec:** docs/security-review.md, “Findings requiring remediation review”; docs/dashboard-iam-change.md preserves the already applied dashboard-only change.

## Global Constraints

- Local code and tests only. No AWS API call, live IAM/lifecycle apply, invocation, email, remote publish, merge, or deployment.
- No new service, paid encryption/backup/retention capability, security exception, skip, soft-fail, baseline, or branch-protection change.
- Preserve all existing dirty changes and the exact ManageProjectDashboard statement.
- Keep the Scheduler disabled. Do not change runtime configuration, Lambda package contents, OIDC trust, IAM attachments, or Terraform backend.
- No commit in this task: pre-existing uncommitted changes must remain separate from this review delta. Capture the task-specific patch from pre-task file snapshots instead.
- Use apply_patch for edits. Do not edit files outside the listed ownership.
- Only the parent may dispatch reviewers. Implementer does not dispatch subagents.
- Remaining scan failures must stay visible and block a green security claim.

### Task 1: Remediate bootstrap findings with regression evidence

**Files:**
- Modify: bootstrap/main.tf
- Modify: bootstrap/oidc.tf
- Test: bootstrap/tests/bootstrap.tftest.hcl
- Modify: docs/security-review.md (dated local evidence, not historical IAM proof)
- Report: .superpowers/sdd/2026-09-07-bootstrap-security-remediation/task-1-report.md

**Interfaces:** Existing bootstrap resources and policy document; no new outputs or variables.

- [x] **Step 1: Capture pre-task files and add regression tests.** Parent captures the three code files before implementation. Append two Terraform plan runs. Test the evaluated resource/policy contract rather than grepping source.

```hcl
run "aborts_incomplete_state_uploads" {
  command = plan
  assert {
    condition = try(one(one(aws_s3_bucket_lifecycle_configuration.state.rule).abort_incomplete_multipart_upload).days_after_initiation == 7, false)
    error_message = "Incomplete state uploads must be aborted after seven days."
  }
}
run "restricts_alarm_reads_to_project" {
  command = plan
  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.deploy.statement :
      contains(statement.actions, "cloudwatch:DescribeAlarms")
    ]) && alltrue([
      for statement in data.aws_iam_policy_document.deploy.statement :
      !contains(statement.actions, "cloudwatch:DescribeAlarms") ||
      toset(statement.resources) == toset(["arn:aws:cloudwatch:ap-northeast-2:123456789012:alarm:url-monitor-*"])
    ])
    error_message = "Alarm reads must remain available only for project alarms."
  }
}
```

- [x] **Step 2: Run bootstrap tests RED.**
Run `.superpowers/tools/terraform-1.16.0/terraform.exe -chdir=bootstrap test -no-color`. Both new runs must fail for the missing abort setting and global alarm-read scope, while existing runs remain passing. Fix test syntax errors before implementation.

- [x] **Step 3: Minimal production changes.**
Within the existing enabled lifecycle rule, after filter, add:
```hcl
abort_incomplete_multipart_upload {
  days_after_initiation = 7
}
```
Preserve the existing rule identity and 90-day noncurrent expiration. This affects only incomplete upload parts once applied; it does not delete completed state objects.
Remove only `"cloudwatch:DescribeAlarms",` from the statement whose resources are `["*"]`. Keep its existing project-alarm-scoped occurrence. Preserve all other policy actions, scope, trust, attachments and the approved dashboard statement. Do not attempt a broad IAM refactor.

- [x] **Step 4: Run GREEN and the complete security scan.**
Run bootstrap fmt, validate and test; run the actual full scanner with `.superpowers/checkov-venv/Scripts/python.exe security/scan.py`.
The expected scan count is 154 passed, 18 failed, 0 skipped, 0 parse errors on the same 30 resources. Verify actual output rather than assuming counts. Gate must still return 1; no skips permitted. Verify CKV_AWS_300 and CKV_AWS_356 no longer appear in failed checks. If CKV356 remains, stop and report the specific action rather than changing additional IAM scope without review.
Run `git diff --check`.

- [x] **Step 5: Update local evidence and hand off.**
Update docs/security-review.md with actual latest counts and two locally remediated findings, clearly NOT applied to AWS. Retain historical before counts and no-risk-exception status. Include links to authoritative AWS S3 abort-lifecycle and CloudWatch authorization documentation if needed. Do not rewrite prior IAM-apply evidence as if it proved the new change.
Write the report with exact RED/GREEN commands/results, scanner counts and gate exit, changed files, no-commit status, and concerns. The parent runs cross-project tests and independent review before any publication.
