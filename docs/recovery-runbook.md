# URL monitor recovery runbook

## Current status

This runbook describes infrastructure code awaiting deployment. Its queues, recovery settings, and tracing must not be treated as live until an approved Terraform deployment is complete.

The supporting bootstrap permissions and SNS key were [applied separately](bootstrap-hardening-apply-2026-09-07.md) on 2026-09-07. That does not deploy these runtime recovery features or authorize a replay or restore drill.

## Failure evidence

Read queue attributes before taking any other queue action. Receiving a message changes its visibility, so coordinate with the incident owner before receiving one. Never automatically replay, purge, or delete messages.

```powershell
aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible MessageRetentionPeriod --region ap-northeast-2
```

Identify the failure stage before deciding on recovery:

- `url-monitor-scheduler-dlq` records Scheduler delivery failures. Establish the original Lambda target and the event age.
- `url-monitor-lambda-dlq` records Lambda execution failures. Establish the original target URL and the event age.

The current handler has no idempotency guarantee. Obtain approval for a bounded replay only after reviewing the message, its age, the original target, and the risk of duplicate state, history, or notification writes. Keep the replay batch explicitly limited and observe its results before requesting another batch.

## DynamoDB recovery

Confirm PITR status using read-only commands:

```powershell
aws dynamodb describe-continuous-backups --table-name url-monitor-state --region ap-northeast-2
aws dynamodb describe-continuous-backups --table-name url-monitor-history --region ap-northeast-2
```

A point-in-time recovery restores to a new table; it does not overwrite the existing table. Check the restored table's TTL and PITR settings. Do not silently switch application traffic to it. Creating a restoration incurs cost and requires an approved deletion plan for the temporary or superseded table.

## Tracing limits

Lambda Active tracing provides sampled, service-level visibility. It does not guarantee a trace for every invocation, detailed HTTP spans, or subsegments for every AWS SDK call.
