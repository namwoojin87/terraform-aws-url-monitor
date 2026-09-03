# URL Monitor Runbook

## Safety first

Use the approved GitHub deployment workflow for runtime changes. It produces an encrypted saved plan, shows a human-readable plan for review, and requires `production` approval before applying that exact plan. Do not run an unreviewed live apply from a workstation.

Keep alert addresses, backend values, state, plan artifacts, credentials, and private age identities out of Git and command history.

## Routine operations

### Inspect current monitor state

Read the table name from Terraform output, then query the stable monitor key:

```powershell
$tableName = terraform -chdir=infra output -raw state_table_name
aws dynamodb get-item --region ap-northeast-2 --table-name $tableName --key '{"monitor_id":{"S":"demo"}}'
```

The valid statuses are:

- `UP` — the most recent check was healthy.
- `PENDING_DOWN` — one failure has been recorded; no outage notification is sent yet.
- `DOWN` — the configured failure threshold was reached; one outage notification has been sent for the transition.

## Inspect recent check history

Read the history table name and query only the stable monitor partition. This returns at most 20 newest records and avoids a table scan.

    $historyTable = terraform -chdir=infra output -raw history_table_name
    aws dynamodb query --region ap-northeast-2 --table-name $historyTable --key-condition-expression "monitor_id = :monitor" --expression-attribute-values '{":monitor":{"S":"demo"}}' --no-scan-index-forward --limit 20

History expiration uses DynamoDB TTL. Items become eligible for deletion after seven days, but deletion is asynchronous.

### Inspect recent execution

```powershell
$logGroup = terraform -chdir=infra output -raw log_group_name
aws logs tail $logGroup --region ap-northeast-2 --since 30m --follow
```

Normal log records include the stable monitor key, health result, status or error category, response time, and transition. Look for `OUTAGE` only on the first transition to `DOWN`, and `RECOVERY` only when a later healthy check restores a `DOWN` monitor to `UP`.

### Confirm alert delivery

The SNS email subscription is incomplete until its confirmation link has been accepted.

```powershell
$topicArn = terraform -chdir=infra output -raw sns_topic_arn
aws sns list-subscriptions-by-topic --region ap-northeast-2 --topic-arn $topicArn
```

The subscription must not remain `PendingConfirmation`. CloudWatch/SNS metrics should reflect one publish for a normal outage transition and one additional publish for its recovery.

## Change a target

1. Edit `infra/monitor.auto.tfvars.json` while preserving the stable map key (for example, `demo`).
2. Keep URLs public HTTP(S), choose expected statuses, and keep the per-request timeout between one and five seconds.
3. Open a pull request and require CI to pass.
4. Merge to `main`.
5. Start `Terraform Deploy` with operation `apply`.
6. Review the saved plan and approve the protected `production` job.
7. Wait for the next scheduled check and confirm the expected state and logs.

For an incident demonstration, `https://monitor-demo.invalid` is a safe reserved invalid target. Restore `https://example.com` through the same reviewed workflow when testing is complete.

## Troubleshooting

### The state does not change

1. Confirm the target configuration was merged and included in the approved deployment.
2. Check the Scheduler schedule and the Lambda log group for recent invocations.
3. Verify the endpoint is reachable from the public internet and the configured expected status is correct.
4. Remember that one ordinary failure should be `PENDING_DOWN`; a second failed scheduled check is required for `DOWN`.

### An alert is missing or repeated

1. Confirm the SNS subscription is confirmed.
2. Inspect Lambda logs for the expected `OUTAGE` or `RECOVERY` transition.
3. Inspect the Lambda error alarm and its delivery path.
4. Check the DynamoDB item before changing configuration; a persisted `DOWN` state intentionally suppresses additional normal outage notifications.
5. If deployment drift is suspected, create and review a new approved plan rather than applying local changes directly.

### A deployment cannot assume its AWS role

1. Confirm the workflow ran from `main` for planning and uses the protected `production` environment for apply.
2. Confirm the repository’s immutable owner and repository IDs are supplied to the bootstrap trust configuration.
3. Confirm the GitHub OIDC provider audience and the plan/deploy role references remain configured through approved repository settings.
4. Repair the trust policy with a reviewed local `bootstrap/` Terraform plan and apply from an MFA-protected, non-root administrative session. This recovery path is necessary because a broken GitHub OIDC trust cannot repair itself. Then retry the runtime deployment with a new saved plan.

### Lambda concurrency configuration fails

The module intentionally does not set a per-function reserved concurrency value. It uses account unreserved concurrency because low-quota accounts can reject small per-function reservations. Keep the 30-second timeout and five-minute schedule unchanged unless an approved design change accounts for operational overlap.

## Enable or pause scheduled checks

`infra/monitor.auto.tfvars.json` is the source of truth. Change `schedule_enabled` through a pull request, require CI to pass, merge to `main`, and run the approved Terraform deployment. Use `true` to enable five-minute checks and `false` to pause them. Do not toggle the Scheduler only in the AWS console because the next Terraform deployment will restore the committed value.

## Destroy runtime resources

Use `Terraform Deploy` with operation `destroy`, review the saved destroy plan, and approve the protected `production` job. This removes runtime monitor resources while retaining the bootstrap state storage, budget notification, and GitHub OIDC roles.

Treat destruction as irreversible for current monitor state and logs. Verify that no incident investigation, alert delivery, or dependent operation still needs the monitor before approving the exact saved destroy plan.

## Full bootstrap teardown

Full bootstrap teardown is exceptional. It can remove the state infrastructure and the ability to manage the monitor through the existing workflow.

1. Destroy runtime resources first through the reviewed destroy workflow.
2. Migrate bootstrap state back to local storage using a reviewed, exact backend configuration.
3. Read and verify the exact state bucket name from Terraform output before any deletion step.
4. Remove the bucket `prevent_destroy` guard only in a reviewed commit.
5. Remove every object version and delete marker from that exact bucket using a reviewed console or command sequence.
6. Create and review a bootstrap destroy plan before applying it with an authorized non-root operator.

Never use a wildcard, unresolved variable, home directory, workspace root, or broad shell path as a deletion target. Stop and seek review if the exact account, resource, or state location cannot be verified.
