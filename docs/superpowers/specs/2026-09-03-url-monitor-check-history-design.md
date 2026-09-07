# URL Monitor Check History — Design

## Summary

Extend the existing AWS URL monitor with a separate DynamoDB history table. Every completed URL check records a small, queryable result while the existing state table continues to drive outage and recovery transitions. History expires automatically after seven days so the feature remains useful for operations practice without turning into a long-term analytics system.

This is an additive change. It does not replace the current state table, alter the five-minute schedule, enable the disabled live schedule, or deploy automatically.

## Goals

- Retain the latest seven days of successful and failed check results.
- Query one monitor's results in timestamp order from DynamoDB.
- Keep the existing `UP` → `PENDING_DOWN` → `DOWN` → `UP` behavior unchanged.
- Keep the live schedule disabled until the user explicitly enables it through a reviewed deployment.
- Preserve least-privilege runtime IAM and on-demand billing.
- Add Python and Terraform regression coverage before any AWS deployment.

## Non-goals

- RDS, relational queries, dashboards, charts, or a public status page.
- Permanent audit retention, backups, point-in-time recovery, streams, or global secondary indexes.
- Cross-monitor analytics or scanning the entire history table.
- Changing the alert threshold, target configuration, schedule interval, or notification behavior.

## Chosen Approach

Create a second table instead of mixing history into the existing state table. The current table has only a partition key and is disposable operational state; changing its key schema would require replacement and create unnecessary migration risk. A separate table gives history a purpose-built composite key while leaving the verified alert state machine untouched.

The alternatives were:

- Keep only CloudWatch logs: cheapest, but it does not demonstrate queryable application data.
- Convert the current state table to a single-table state-and-history model: fewer resources, but requires a key-schema migration and couples two different retention rules.
- Add RDS PostgreSQL: familiar SQL, but disproportionate cost and operations for a five-minute serverless monitor.

## Architecture

```text
EventBridge Scheduler (5 minutes)
             |
             v
        Lambda checker
          |       |
          |       +----> DynamoDB check history (7-day TTL)
          |
          +------------> DynamoDB current state
          |
          +------------> SNS transition notifications
```

The existing state write remains the source of truth for alert suppression. The history write is an additional operational record and is never read by the Lambda during normal checks.

## History Table

Terraform creates `${project_name}-history` with on-demand billing:

- Partition key: `monitor_id` (string).
- Sort key: `checked_at` (string, UTC ISO 8601).
- TTL attribute: `expires_at` (number, epoch seconds).
- No secondary indexes, streams, backups, or point-in-time recovery.

Each item contains:

- `monitor_id`: stable target key.
- `checked_at`: check timestamp and range key.
- `healthy`: Boolean result.
- `state`: resulting `UP`, `PENDING_DOWN`, or `DOWN` state.
- `status_code`: HTTP status when available.
- `response_ms`: elapsed request time when available.
- `error_category`: failure classification when available.
- `expires_at`: timestamp seven days after the check.

Optional values are omitted instead of written as null. Full error messages and target URLs are not stored in history; categories are sufficient for the learning and troubleshooting use case and reduce duplicated or unexpectedly sensitive text.

DynamoDB TTL deletion is asynchronous, so an expired item can remain visible for some time after seven days. The retention setting is therefore an expiry policy, not an exact deletion deadline.

## Runtime Flow

For each valid target, the Lambda keeps the existing order:

1. Read current state.
2. Perform the HTTP check.
3. Decide the next state and transition.
4. Publish a transition notification when required.
5. Persist current state.
6. Persist one history item.

The history repository has one operation: `put(monitor_id, checked_at, result, state, expires_at)`. The Lambda entry point creates it from a new `HISTORY_TABLE_NAME` environment variable and passes it into `run` separately from the current-state repository.

History persistence failure is treated as an internal target failure: it is logged, remaining targets are still processed, and the invocation fails after the loop so the existing Lambda error alarm can report it. Because current state is written first, a history failure cannot roll back a successfully delivered outage or recovery transition. Scheduler retry can create another item with a later check time; the history is operational evidence rather than an exactly-once event ledger.

Malformed target configuration or a checker failure produces no history item because there is no completed check result. Existing per-target isolation remains unchanged.

## Terraform and IAM

The module will:

- Add the `${project_name}-history` DynamoDB table.
- Pass its name as `HISTORY_TABLE_NAME` to Lambda.
- Grant Lambda `dynamodb:PutItem` only on the history table while retaining `GetItem` and `PutItem` on the state table.
- Export `history_table_name` from the module and live root.
- Pass `history_ttl_days = 7` in the Scheduler payload.
- Add an explicit `schedule_enabled` Boolean input and map it to the Scheduler's `ENABLED` or `DISABLED` state. The module default remains enabled for reusable-module compatibility, while the live root passes `false` so deploying this feature cannot restart scheduled checks accidentally.

The existing GitHub deploy role already scopes DynamoDB table management to `${project_name}-*`, so the new table stays within the reviewed resource boundary. The plan role remains read-only apart from Terraform state operations.

## Testing

Python tests will cover:

- Exact history item serialization and omission of unavailable optional fields.
- A successful check writing state first and then one history record.
- A failed HTTP result writing its error category and resulting state.
- A history-write error not skipping later targets and causing the final invocation to fail.
- No history item for malformed configuration or an exception before a check result exists.

Terraform tests will cover:

- On-demand billing, composite keys, and enabled TTL on the history table.
- Lambda environment wiring and least-privilege table permissions.
- Scheduler payload retention value.
- Explicit disabled schedule wiring in the live root.
- Module and live-root history table outputs.

The complete existing Python, Terraform, formatting, validation, and TFLint suites must remain green.

## Operations and Cost

At a five-minute interval, each target creates 288 small items per day and about 2,016 items during a seven-day retention window. Five targets create about 10,080 retained items. On-demand DynamoDB and automatic TTL avoid provisioned-capacity or cleanup jobs, but the feature has a small nonzero storage and write cost.

The runbook will include a DynamoDB query for a single `monitor_id`, ordered newest first with a small result limit. It will also document that enabling or disabling scheduled checks is a reviewed Terraform input change, not a console-only toggle. Deployment remains a separate manual GitHub Actions run with a reviewed saved plan and production approval. The live Scheduler must remain in its current disabled state unless the user separately approves enabling it.
