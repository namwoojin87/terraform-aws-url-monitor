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

### Inspect recent check history

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

## Weekly infrastructure drift check

The `Terraform Drift Check` workflow runs on `main` every Monday at 00:17 UTC (09:17 Asia/Seoul). To run it immediately, open GitHub Actions, select **Terraform Drift Check**, choose **Run workflow**, and keep branch **main**. Other branches are skipped because the existing OIDC plan-role trust permits only `main`.

The workflow uses the existing plan role and live `infra/terraform.tfstate` backend with locking. It runs `terraform plan -json -detailed-exitcode` without saving a plan or applying anything. It does not inspect the separately protected bootstrap configuration, untracked AWS resources, DynamoDB item contents, or endpoint availability. The workflow leaves the URL-check Scheduler unchanged; its committed desired state is disabled, and detected differences are reported.

Read the job summary as follows:

| Result | Meaning | Next action |
| --- | --- | --- |
| CLEAN / successful run | No observed drift or pending configuration changes | None |
| CHANGES DETECTED / failed run | External changes, proposed configuration changes, or output differences need review | Compare with recent commits and deployments; decide whether to keep the code or update it, then use the protected deployment workflow |
| ERROR / failed run | Planning could not complete; infrastructure health is unknown | Check the failed setup step, credentials, required inputs, or state locking and rerun |

**Observed external changes** come from Terraform refresh events. **Proposed configuration changes** are the reconciliation plan and can include committed but undeployed changes, not just manual AWS edits. Data-source reads are omitted from resource-change lists. Output-only or otherwise unclassified nonempty plans still require review, even without listed resource changes. A run during an active deployment can observe temporary differences or encounter a state lock; let deployment finish and rerun. Never disable locking to make a check pass.

The planner captures raw JSON and diagnostics in memory, publishing only resource addresses and action categories. Attribute values, Terraform outputs, raw diagnostics, and plaintext plans are not uploaded as artifacts or included in the report. Keep secrets out of resource names and instance keys as these form resource addresses. For detailed diagnosis, use the existing protected deployment plan and review it before any apply. Local Python imports under `lambda/` can leave bytecode that changes the packaged Lambda hash; use a clean checkout when checking drift locally.

GitHub Actions email/web delivery depends on the account's notification preferences. Enable **Actions** notifications and choose **failed workflows only** if desired; this feature does not alter notification settings or create issues. Scheduled notifications are associated with the workflow's schedule actor. GitHub may delay scheduled runs and disables public-repository schedules after 60 days without repository activity; check the Actions page when resuming a dormant project. See [GitHub schedule behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule) and [workflow notifications](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs).

The planner has a ten-minute timeout, requests a graceful interrupt and waits up to 30 seconds for lock cleanup before forced termination. A forced runner shutdown may still leave a lock: establish that no operation owns it before considering a manual unlock; this workflow never force-unlocks state.

The runtime provider lockfile includes Windows and Linux package hashes because drift initialization is read-only. When intentionally updating providers, run `terraform -chdir=infra providers lock -platform=windows_amd64 -platform=linux_amd64`, review the selected versions and signed checksums, and commit the lockfile. CI initializes with the same read-only flag and validates the configuration on Linux so missing platform hashes fail before merge. See [cross-platform provider locking](https://developer.hashicorp.com/terraform/cli/commands/providers/lock).

The check performs AWS reads plus Terraform backend locking and consumes a short GitHub runner job. It creates no AWS runtime services. Terraform behavior is documented in the [plan command reference](https://developer.hashicorp.com/terraform/cli/commands/plan) and [machine-readable UI reference](https://developer.hashicorp.com/terraform/internals/machine-readable-ui).

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
