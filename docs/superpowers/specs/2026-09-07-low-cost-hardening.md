# Approved low-cost hardening scope

The user approved the written `outputs/security-hardening-review-2026-09-07.md` proposal on 2026-09-07 with “ㄱㄱ”, including the one-key SNS option and its stated cost caveat. This file records that scope for implementation; it does not authorize live IAM changes, Terraform apply, security exceptions, production scheduling, destructive tests, or a merge.

## Deliverable

- Enable point-in-time recovery on both existing DynamoDB tables; keep on-demand billing and seven-day item TTL.
- Separate Scheduler delivery failures and Lambda execution failures into two Standard SQS queues: `url-monitor-scheduler-dlq` and `url-monitor-lambda-dlq`. Use explicit SSE-SQS and 1,209,600-second retention. No automatic consumer, redrive, or replay.
- Keep Scheduler delivery retry age 300 seconds / attempts 1. Set unqualified Lambda asynchronous event configuration to age 300 seconds / code-error retries 0. This reduces retries but does not provide exactly-once processing.
- Enable Lambda Active tracing. Grant only `xray:PutTraceSegments` and `xray:PutTelemetryRecords`; those actions require resource `*`. Do not claim HTTP or every SDK call has detailed subsegments.
- Expand the optional authenticated CloudWatch dashboard from 13 to 20 displayed series: four Scheduler delivery/DLQ signals, Lambda DeadLetterErrors, and visible-message count for each queue. Existing AWS service metrics only, 300-second period, Seoul. No new alarms, custom metrics, query widgets, public sharing, or automatic recovery.
- Bootstrap owns exactly one symmetric customer-managed SNS key, with alias `alias/url-monitor-alerts`, annual rotation, 30-day deletion window and Terraform `prevent_destroy`. Runtime resolves its ARN by alias. Do not change Terraform state encryption or share this key with other services.
- Preserve Lambda and CloudWatch alarm publishing to the encrypted SNS topic. Constrain runtime key use to the exact key/topic and CloudWatch service grants to the exact account/alarm/topic. Bootstrap key policy delegates account IAM permissions without referencing a runtime role that may not exist yet.
- Add only the project-specific deploy permissions needed to manage these resources. No GitHub KMS administration or bootstrap-state access. Preserve OIDC trust, state prefix, existing role boundaries and production approval.

## Fixed constraints

- Region `ap-northeast-2`; Terraform `>= 1.16.0, < 2.0.0`; AWS provider `>= 6.60.0, < 7.0.0`.
- Python Lambda `python3.13`, 128 MB, timeout 30 seconds. Logs and item TTL remain seven days.
- Production `schedule_enabled` default remains `false`; reusable module default remains `true`. Production scheduler stays OFF throughout this task.
- No reserved concurrency (last observed account limit was 10), quota changes, VPC/NAT, EC2, RDS, extra keys, notification tests, or actual restoration.
- Initial key storage is USD 1/month plus requests/tax. The first two rotations each add USD 1/month storage. A paused scheduler does not stop key storage charges. Do not promise a total monthly cost or remaining free allowance.
- Full pinned Checkov scan remains fail-closed. No suppressions, skips, baselines, soft-fail, or unapproved exceptions. Recompute findings after additions.

## Acceptance and handoff

Use test-first Terraform configuration tests, the existing Python suite, formatting/validation/lint and a full Checkov scan. Policy tests must inspect real policy document inputs, not the mocked empty JSON document. Review each implementation task and the integrated change independently. Record implementation versus currently deployed state separately.

Actual deployment needs a fresh bootstrap plan and explicit authority for its exact IAM/key changes, then a fresh saved runtime plan and production approval. Both encrypted publisher paths need separately authorized delivery verification. Do not update submission materials to show undeployed capabilities as live.

## Design references

- [Scheduler asynchronous Lambda delivery](https://docs.aws.amazon.com/lambda/latest/dg/with-eventbridge-scheduler.html)
- [Scheduler DLQ](https://docs.aws.amazon.com/scheduler/latest/UserGuide/configuring-schedule-dlq.html)
- [Lambda asynchronous errors](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-error-handling.html)
- [SNS key management](https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html)
- [SNS encryption context](https://docs.aws.amazon.com/sns/latest/dg/sns-enable-encryption-for-topic.html)
- [Default KMS policy and IAM delegation](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html)
- [KMS pricing](https://aws.amazon.com/kms/pricing/)

Combining the documented CloudWatch source restrictions and SNS topic encryption context is a policy-design inference, not proof of live delivery. IAM propagation also remains a deployment consideration.
