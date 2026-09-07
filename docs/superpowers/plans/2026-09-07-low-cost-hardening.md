# Low-cost hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add approved recovery, failure evidence, tracing and encrypted notifications without enabling production scheduling.

**Architecture:** The reusable runtime module owns the two delivery-stage DLQs, PITR and operational signals. Bootstrap owns the single SNS key and deployment-role permissions; runtime looks up the existing key by alias. Changes remain local/PR code until fresh plans receive separate deployment approval.

**Tech Stack:** Terraform 1.16.0, AWS provider 6.x, Python 3.13 Lambda, pytest, Terraform mock tests, TFLint, pinned Checkov 3.3.16.

**Spec:** `docs/superpowers/specs/2026-09-07-low-cost-hardening.md` (approved written proposal, including SNS cost choice).

## Global Constraints

- Region `ap-northeast-2`; Terraform `>= 1.16.0, < 2.0.0`; AWS provider `>= 6.60.0, < 7.0.0`.
- Python Lambda `python3.13`, 128 MB, timeout 30 seconds. Logs and item TTL remain seven days.
- Production `schedule_enabled` default remains `false`; reusable module default remains `true`. Production scheduler stays OFF throughout this task.
- No reserved concurrency, quota changes, VPC/NAT, EC2, RDS, extra keys, notification tests, or actual restoration.
- No suppressions, skips, baselines, soft-fail, or unapproved exceptions. Full scan may legitimately remain nonzero.
- Preserve GitHub OIDC trust, Terraform state boundary and approval workflow. No apply, merge, schedule enablement, live IAM mutation or broad new permissions.
- Tests inspect `data.aws_iam_policy_document.<name>.statement` inputs; mocked `.json` is empty and is not policy proof.

## File responsibilities and execution

Use existing isolated worktree and branch `codex/monitoring-security-evidence`; baseline `583c6a5700ea4ed8efdc1d33f0b74604b2e0640a`. Existing dirty `docs/security-review.md` corrects two SNS descriptions and belongs to the controller. Do not discard or accidentally stage it.

Task 1 adds runtime reliability and matching deploy permissions. Task 2 adds SNS encryption and its required bootstrap/read/publish policies. Run only one implementer at a time because both touch module main/IAM and bootstrap IAM. A separate reviewer gates each task. The controller owns the spec/plan, final evidence documentation and final whole-change review.

Tools from repository root in PowerShell:

```powershell
$tf = '.superpowers/tools/terraform-1.16.0/terraform.exe'
& $tf -chdir=modules/url-monitor test
& $tf -chdir=bootstrap test
& $tf fmt -check -recursive bootstrap infra modules
& $tf -chdir=modules/url-monitor validate
& $tf -chdir=bootstrap validate
& $tf -chdir=infra validate
& '.superpowers/checkov-venv/Scripts/python.exe' -m pytest -q
```

Terraform tests use existing mock providers and do not contact AWS. Python executable may require sandbox escalation. No package/version upgrades are required. On this Windows host focused test filters require backslashes; reject an `Unknown test file` warning or zero executed tests even if the process exits zero.

### Task 1: Recoverability, failure separation and operational signals

**Files:**
- Modify: `modules/url-monitor/main.tf`, `modules/url-monitor/iam.tf`, `modules/url-monitor/dashboard.tf`, `modules/url-monitor/outputs.tf`, `infra/outputs.tf`, `bootstrap/oidc.tf`.
- Create: `modules/url-monitor/reliability.tf`, `modules/url-monitor/tests/reliability.tftest.hcl`, `bootstrap/tests/reliability.tftest.hcl`, `docs/recovery-runbook.md`.
- Modify tests: `modules/url-monitor/tests/module.tftest.hcl` only where new supported namespaces need inclusion.

**Interfaces:**
- Consumes: existing `var.project_name`, `var.tags`, Lambda checker, Scheduler monitor, state/history tables, account and region data, existing dashboard count switch.
- Produces: `aws_sqs_queue.scheduler_dlq`, `aws_sqs_queue.lambda_dlq`, `aws_lambda_function_event_invoke_config.checker`; module/root outputs `scheduler_dlq_url`, `lambda_dlq_url`. No new input needed.
- Task 2 consumes existing Lambda role and preserves Task 1 policies, queues, dashboard and tests.

- [x] **Step 1: Add failing configuration tests.** Make each new test file self-contained with AWS mock provider, caller/region/IAM-document mock data and computed ARN overrides based on the existing test patterns. In module tests supply the existing required email, target and zip inputs. Assert these behaviors, with this representative run expanded into separate focused runs for IAM/dashboard:

```hcl
run "separates_failure_stages" {
  command = plan
  assert {
    condition = aws_sqs_queue.scheduler_dlq.name == "url-monitor-scheduler-dlq" && aws_sqs_queue.lambda_dlq.name == "url-monitor-lambda-dlq"
    error_message = "Delivery-stage and execution-stage failures need distinct queues."
  }
  assert {
    condition = alltrue([for q in [aws_sqs_queue.scheduler_dlq, aws_sqs_queue.lambda_dlq] : q.sqs_managed_sse_enabled && !q.fifo_queue && q.message_retention_seconds == 1209600])
    error_message = "DLQs must be Standard, SSE-SQS encrypted and retained for 14 days."
  }
  assert {
    condition = one(aws_lambda_function.checker.dead_letter_config).target_arn == aws_sqs_queue.lambda_dlq.arn && one(one(aws_scheduler_schedule.monitor.target).dead_letter_config).arn == aws_sqs_queue.scheduler_dlq.arn
    error_message = "Each stage must send to its own DLQ."
  }
  assert {
    condition = aws_lambda_function_event_invoke_config.checker.maximum_retry_attempts == 0 && aws_lambda_function_event_invoke_config.checker.maximum_event_age_in_seconds == 300 && aws_lambda_function_event_invoke_config.checker.function_name == aws_lambda_function.checker.function_name
    error_message = "Unqualified async execution uses age 300 and zero code-error retries."
  }
  assert {
    condition = one(aws_dynamodb_table.state.point_in_time_recovery).enabled && one(aws_dynamodb_table.history.point_in_time_recovery).enabled && one(aws_lambda_function.checker.tracing_config).mode == "Active"
    error_message = "Both tables need PITR and Lambda needs Active tracing."
  }
}
```

IAM assertions locate statements by Sid and compare sets exactly: Lambda `SendExecutionFailures` actions `sqs:SendMessage`, resource lambda queue ARN; Scheduler `SendDeliveryFailures` same action and scheduler queue ARN; Lambda `WriteSampledTraces` exactly the two X-Ray actions and `*`. Bootstrap grants below must have exact action/resource sets. Dashboard tests decode JSON, select type metric widgets and flatten `properties.metrics`; count exactly 20 and assert the seven new full metric rows with appropriate dimensions and region/period. Assert scheduler stays DISABLED when input false, and retries 300/1 are unchanged.

- [x] **Step 2: Run both focused tests before production edits.**

```powershell
& $tf -chdir=modules/url-monitor test '-filter=tests\reliability.tftest.hcl'
& $tf -chdir=bootstrap test '-filter=tests\reliability.tftest.hcl'
```

Expected RED: missing queue/event config/PITR/tracing/policy resources or fields. Record actual output; do not count fixture syntax failures as sufficient RED.

- [x] **Step 3: Add runtime resources and wiring.** Use explicit false FIFO fields to make intended semantics and mock assertions unambiguous.

```hcl
resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.project_name}-scheduler-dlq"
  fifo_queue                = false
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled    = true
  tags                      = var.tags
}
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.project_name}-lambda-dlq"
  fifo_queue                = false
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled    = true
  tags                      = var.tags
}
resource "aws_lambda_function_event_invoke_config" "checker" {
  function_name                = aws_lambda_function.checker.function_name
  maximum_event_age_in_seconds  = 300
  maximum_retry_attempts        = 0
}
```

Add `point_in_time_recovery { enabled = true }` to each table; Lambda `dead_letter_config { target_arn = aws_sqs_queue.lambda_dlq.arn }` and `tracing_config { mode = "Active" }`; Scheduler target `dead_letter_config { arn = aws_sqs_queue.scheduler_dlq.arn }`. Preserve existing policy-before-target dependencies and make schedule depend on event invoke config so it cannot start with default code-error retry behavior. Do not add Lambda on-failure destinations as well as DLQ, event-source mappings or redrive policies.

Append these statements to existing policy documents, using the stated Sids:

```hcl
# Lambda policy
statement {
  sid       = "SendExecutionFailures"
  actions   = ["sqs:SendMessage"]
  resources = [aws_sqs_queue.lambda_dlq.arn]
}
statement {
  sid       = "WriteSampledTraces"
  actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
  resources = ["*"]
}
# Scheduler policy
statement {
  sid       = "SendDeliveryFailures"
  actions   = ["sqs:SendMessage"]
  resources = [aws_sqs_queue.scheduler_dlq.arn]
}
```

Append separate bootstrap deploy statements (keep existing statement order):

```hcl
statement {
  sid       = "ManageProjectPointInTimeRecovery"
  actions   = ["dynamodb:UpdateContinuousBackups"]
  resources = [for suffix in ["state", "history"] : "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project_name}-${suffix}"]
}
statement {
  sid       = "ManageProjectAsyncFailurePolicy"
  actions   = ["lambda:GetFunctionEventInvokeConfig", "lambda:PutFunctionEventInvokeConfig", "lambda:DeleteFunctionEventInvokeConfig"]
  resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-checker"]
}
statement {
  sid = "ManageProjectFailureQueues"
  actions = ["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:GetQueueAttributes", "sqs:ListQueueTags", "sqs:SetQueueAttributes", "sqs:TagQueue", "sqs:UntagQueue"]
  resources = [for suffix in ["scheduler-dlq", "lambda-dlq"] : "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-${suffix}"]
}
```

Do not add SQS ListQueues, GetQueueUrl or KMS rights in this task. The pinned provider uses the returned queue URL, attributes and tagging APIs; no URL lookup is needed. Outputs reference each queue `.url` and root forwards module outputs.

- [x] **Step 4: Extend the dashboard using existing widget conventions.** Add three width-8/height-6 metric widgets below existing rows. First uses Sum for Scheduler, second Lambda Sum, third SQS Maximum. All have 300-second period and current module region. Full metrics (one row per series):

```hcl
["AWS/Scheduler", "TargetErrorCount", "ScheduleGroup", aws_scheduler_schedule_group.monitor.name]
["AWS/Scheduler", "InvocationDroppedCount", "ScheduleGroup", aws_scheduler_schedule_group.monitor.name]
["AWS/Scheduler", "InvocationsSentToDeadLetterCount", "ScheduleGroup", aws_scheduler_schedule_group.monitor.name]
["AWS/Scheduler", "InvocationsFailedToBeSentToDeadLetterCount", "ScheduleGroup", aws_scheduler_schedule_group.monitor.name]
["AWS/Lambda", "DeadLetterErrors", "FunctionName", aws_lambda_function.checker.function_name]
["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.scheduler_dlq.name]
["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.lambda_dlq.name]
```

Update the existing dashboard namespace allowlist to include AWS/Scheduler and AWS/SQS, not a wildcard. Keep disabled-count and existing labels/data interpretation assertions.

- [x] **Step 5: Add the manual recovery runbook.** State that this is code awaiting deployment. Describe: read only queue attributes first, coordinate before receiving because receive changes visibility, never automatically replay/purge/delete; identify stage, event age and original target; current handler has no idempotency guarantee; approval before a bounded replay; PITR restores to a new table and table TTL/PITR settings need checking, traffic must not silently switch; actual restoration creates cost and needs a deletion plan; Active tracing is sampled service-level visibility only. Include these read-only examples and no live mutations:

```powershell
aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible MessageRetentionPeriod --region ap-northeast-2
aws dynamodb describe-continuous-backups --table-name url-monitor-state --region ap-northeast-2
aws dynamodb describe-continuous-backups --table-name url-monitor-history --region ap-northeast-2
```

- [x] **Step 6: Verify and commit only owned files.** Run focused GREEN, then complete module/bootstrap test suites, fmt/validate and Python suite once. Record exact counts and evidence in the task report. Commit with `feat: add recovery and failure evidence for URL monitoring`. No AWS, push, workflow dispatch or PR changes.

### Task 2: One bootstrap-owned SNS key with constrained publishers

**Files:**
- Create: `bootstrap/alerts-encryption.tf`, `bootstrap/tests/alerts-encryption.tftest.hcl`, `modules/url-monitor/alerts-encryption.tf`, `modules/url-monitor/tests/alerts-encryption.tftest.hcl`, `infra/alerts-encryption.tf`, `docs/sns-encryption-runbook.md`.
- Modify: `bootstrap/oidc.tf`, `bootstrap/outputs.tf`, `modules/url-monitor/main.tf`, `modules/url-monitor/variables.tf`, `infra/main.tf`.
- Modify existing module test inputs: `modules/url-monitor/tests/module.tftest.hcl`, `modules/url-monitor/tests/reliability.tftest.hcl`; normalize ARN fixtures to Seoul if needed.
- Add static lifecycle check: `tests/test_alerts_key_lifecycle.py`.

**Interfaces:**
- Consumes: Task 1 policies/queues unchanged; existing Lambda role, SNS topic, account data and region data. Bootstrap owns current account and project inputs.
- Produces: required module `alerts_kms_key_arn` string; root data `aws_kms_key.alerts` resolved with alias `alias/url-monitor-alerts`; bootstrap key/alias and `alerts_kms_key_arn` output; runtime exact-key IAM grant and exact-alarm SNS topic policy. No new GitHub secret/variable or bootstrap-state access.

- [x] **Step 1: Write failing key/publisher tests before implementation.** New test files follow existing AWS mocks; use key ARN `arn:aws:kms:ap-northeast-2:123456789012:key/11111111-1111-1111-1111-111111111111`, account 123456789012 and Seoul region. Test default required input forwarding and invalid key ARN rejection. Do not weaken existing tests.

```hcl
run "keeps_single_rotating_alert_key" {
  command = plan
  assert {
    condition = aws_kms_key.alerts.enable_key_rotation && aws_kms_key.alerts.rotation_period_in_days == 365 && aws_kms_key.alerts.deletion_window_in_days == 30 && !aws_kms_key.alerts.multi_region && aws_kms_key.alerts.key_usage == "ENCRYPT_DECRYPT" && aws_kms_key.alerts.customer_master_key_spec == "SYMMETRIC_DEFAULT"
    error_message = "The single SNS key must retain the approved rotation and deletion boundaries."
  }
  assert {
    condition = aws_kms_alias.alerts.name == "alias/url-monitor-alerts" && aws_kms_alias.alerts.target_key_id == aws_kms_key.alerts.key_id
    error_message = "Runtime must resolve the one bootstrap-owned key."
  }
}
```

Add assertions on real document `.statement` inputs: account-root delegation `kms:*`/`*`; CloudWatch service only crypto actions/`*`, exact alarm/account/topic context; deploy DescribeKey on exact key only and no new KMS administration actions. Module asserts topic encryption ARN, Lambda crypto exact key and ViaService/topic conditions, alarm topic ARN, exact CloudWatch topic policy and validation. Add lifecycle source test:

```python
from pathlib import Path

def test_alert_key_has_explicit_destroy_guard():
    source = (Path(__file__).resolve().parents[1] / "bootstrap" / "alerts-encryption.tf").read_text(encoding="utf-8")
    assert "prevent_destroy = true" in source
```

- [x] **Step 2: Run focused tests and record RED.**

```powershell
& $tf -chdir=bootstrap test '-filter=tests\alerts-encryption.tftest.hcl'
& $tf -chdir=modules/url-monitor test '-filter=tests\alerts-encryption.tftest.hcl'
& '.superpowers/checkov-venv/Scripts/python.exe' -m pytest tests/test_alerts_key_lifecycle.py -q
```

Expected missing key/policy resources and lifecycle file, not syntax errors. Existing module tests gain the required input only when it exists, then both suites must pass.

- [x] **Step 3: Implement bootstrap key policy, key, alias and read-only deploy grant.** Use constructed project ARNs to avoid nonexistent role references/cycles:

```hcl
locals {
  alerts_topic_arn = "arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-alerts"
  alerts_alarm_arn = "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-lambda-errors"
}
data "aws_iam_policy_document" "alerts_key" {
  statement {
    sid = "EnableAccountIAMPermissions"
    actions = ["kms:*"]
    resources = ["*"]
    principals {
      type = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid = "AllowProjectAlarmEncryption"
    actions = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test = "StringEquals"
      variable = "aws:SourceAccount"
      values = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test = "ArnEquals"
      variable = "aws:SourceArn"
      values = [local.alerts_alarm_arn]
    }
    condition {
      test = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values = [local.alerts_topic_arn]
    }
  }
}
resource "aws_kms_key" "alerts" {
  description = "SNS encryption for ${var.project_name} alerts"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  key_usage = "ENCRYPT_DECRYPT"
  multi_region = false
  enable_key_rotation = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy = data.aws_iam_policy_document.alerts_key.json
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_alias" "alerts" {
  name = "alias/${var.project_name}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}
```

Bootstrap output key ARN. Append deploy Sid `DescribeProjectAlertKey`, actions `["kms:DescribeKey"]`, resources `[aws_kms_key.alerts.arn]`. No key management for GitHub roles. Existing plan ReadOnlyAccess handles DescribeKey with account IAM delegation.

- [x] **Step 4: Wire runtime encryption without a policy cycle.** Root lookup and module input:

```hcl
data "aws_kms_key" "alerts" { key_id = "alias/url-monitor-alerts" }
# Added to module url_monitor:
# alerts_kms_key_arn = data.aws_kms_key.alerts.arn
```

Module variable string has no default; validate `can(regex("^arn:aws:kms:ap-northeast-2:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.alerts_kms_key_arn))` with clear message requiring a Seoul key ARN, not alias. Add module locals `alerts_topic_arn` / `alerts_alarm_arn` using `data.aws_region.current.region`, account and project. Separate `data.aws_iam_policy_document.lambda_alerts_encryption`:

```hcl
statement {
  sid = "PublishEncryptedAlerts"
  actions = ["kms:GenerateDataKey*", "kms:Decrypt"]
  resources = [var.alerts_kms_key_arn]
  condition {
    test = "StringEquals"
    variable = "kms:ViaService"
    values = ["sns.${data.aws_region.current.region}.amazonaws.com"]
  }
  condition {
    test = "StringEquals"
    variable = "kms:EncryptionContext:aws:sns:topicArn"
    values = [local.alerts_topic_arn]
  }
}
```

Attach `aws_iam_role_policy.lambda_alerts_encryption` name `${var.project_name}-encrypted-alerts`, role existing Lambda ID, policy document JSON. SNS topic sets `kms_master_key_id = var.alerts_kms_key_arn` and depends on this separate inline policy. Existing Lambda policy depends on SNS topic, so do not put this dependency on the existing combined policy.

Create `data.aws_iam_policy_document.alerts_topic` with one Sid `AllowProjectAlarmPublish`, Service cloudwatch.amazonaws.com, action sns:Publish, exact topic ARN, StringEquals SourceAccount and ArnEquals SourceArn exact alarm. Create `aws_sns_topic_policy.alerts` on actual SNS topic ARN, JSON document. Alarm depends on topic policy and keeps the existing topic action. Same-account Lambda and deploy rights remain authorized by their IAM policies; do not add broad account Publish to the topic policy. Do not put ViaService on the CloudWatch key statement.

- [x] **Step 5: Document the two-stage deployment and lifecycle boundary.** `docs/sns-encryption-runbook.md` must say code awaiting deployment; bootstrap needs separate explicit permission/plan for key and IAM changes before runtime alias lookup can plan; no live verification yet. Explain both publisher paths, scope conditions, IAM propagation, paused schedule, sampled tracing unrelated to encryption, SNS subjects/attributes and delivered email are outside SSE. Require separate approval for bounded publisher tests without publishing arbitrary alerts now. State initial USD 1/month + requests/tax, first two rotations add USD 1/month each, Scheduler OFF does not stop charges, prevent_destroy is configuration-only protection and deletion/key-disable needs distinct review. Never recommend removing guard or bypassing policy lockout safety.

- [x] **Step 6: Verify and commit owned files.** Focused GREEN, complete module/bootstrap mock suites, fmt/validate, Python suite once, and self-review the policy graph. Record counts and exact commands. Commit with `feat: encrypt SNS alerts with a bootstrap-managed key`. No apply, live notifications, push, PR mutation or exceptions.

## Integration acceptance (controller)

- Read both reports and independently review per-task commit ranges, then the full change against the approved scope.
- Run fresh full tests/format/validate/lint and full pinned Checkov without suppressions. Do not compute the new count by subtracting five from 18; new resources may add findings.
- Update `docs/security-review.md` and a dated implementation evidence note with actual results and explicit live-state distinction. Preserve prior single-invocation evidence and pending exception decisions.
- No live deployment until exact bootstrap and saved runtime plans/permissions are separately approved. No production schedule activation or merge.

## Preflight self-review

| Requirement | Coverage |
| --- | --- |
| PITR, two failure stages, 300/0, Active tracing | Task 1 tests/resources/IAM |
| 20-series optional private dashboard | Task 1 JSON assertions and widgets |
| One SNS key and both scoped publishers | Task 2 bootstrap/runtime policy tests |
| Cost/key lifecycle and manual recovery limits | Task 1/2 runbooks |
| OFF, exact IAM, state boundary, no waivers/apply | Global constraints and integration checks |
| Actual evidence, remaining gate, independent review | Integration acceptance |

Interfaces have no new unspecified variables or outputs; no unresolved placeholders remain. Existing OIDC and state tests are retained. Plan is limited to the approved proposal, not a blanket resolution of all security findings.
