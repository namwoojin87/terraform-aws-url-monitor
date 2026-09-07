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

## Operations dashboard

The new dashboard is controlled by `dashboard_enabled`. The reusable module defaults to `false`; the production input now requests `true` while keeping `schedule_enabled = false`. A local Terraform change is not a live deployment: verify the approved apply before claiming the dashboard exists.

The dashboard-scoped bootstrap IAM update was approved, applied, and verified on 2026-09-07. See [the permission verification record](dashboard-iam-change.md). It is not yet published to GitHub, and the dashboard itself remains undeployed. Do not reapply the historical saved plan or run the older `main` bootstrap configuration, which does not yet include the approved statement. Publish and review the source patch before the next bootstrap operation.

Deployment order:

1. Review the bootstrap plan with a non-root operator. The new IAM statement grants only `cloudwatch:GetDashboard`, `cloudwatch:PutDashboard`, and `cloudwatch:DeleteDashboards` on the exact `${project_name}-operations` dashboard. Dashboard ARNs are global and have no region component. Obtain explicit authorization before this access change.
2. Apply only the reviewed bootstrap plan through the existing bootstrap recovery procedure. Do not give the GitHub role general CloudWatch administration or change its OIDC trust.
3. Merge the reviewed runtime change once the applicable checks and unresolved security findings have been addressed. Create a **new** protected `Terraform Deploy` plan; do not reuse an earlier saved plan.
4. Confirm the plan adds one dashboard, retains Scheduler `DISABLED`, and has no unexpected resource changes. Approve that exact plan through `production`.
5. Open the authenticated console URL from `terraform -chdir=infra output -raw dashboard_url`. A null output means the dashboard is disabled. Confirm the widgets render in Seoul and inspect their actual data window.

The dashboard displays Lambda invocation/error/throttle/runtime metrics, SNS publication/delivery/failure metrics, and read/write capacity metrics for both DynamoDB tables. It uses 13 existing metric series and no custom metrics, Logs Insights queries, or public sharing. The operator needs their own authorized CloudWatch read access; the Lambda execution role receives no new permissions.

Interpretation limits:

- The pause banner is Terraform configuration, not a live Scheduler health check.
- Missing data while checks are paused is expected and does not prove endpoint health.
- Lambda `Duration` measures function runtime, not per-URL response latency or availability. Query DynamoDB history for per-URL measurements.
- SNS delivery metrics are topic-wide service delivery reports, not proof a recipient read an email.
- DynamoDB capacity consumption is not a count of stored items.

CloudWatch currently includes three custom dashboards with up to 50 metrics each in its free allowance. Check all dashboards in the account before applying; the allowance is shared, not reserved for this project. No zero-cost guarantee is made for AWS usage or optional future features. See [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) and [dashboard resource permissions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudwatch.html).

## Security scan and review

`Terraform Security` runs Checkov in a separate Python environment on pull requests, pushes to `main`, and manual dispatches. It needs repository read access only: no AWS credentials, OIDC permission, deployment permission, or production environment secrets. The workflow first tests the gate against real insecure, clean, empty, malformed, and suppressed fixtures, then scans all repository Terraform.

The gate fails on findings, unapproved skips, parser errors, empty scans, and unexpected scanner failure. A summary and raw scanner evidence are uploaded even when the scan fails, provided the scanner produced them. Setup failures are reported as missing evidence, never as a clean scan. Reports have 14-day artifact retention; local `security/reports/` is ignored by Git.

Use a dedicated virtual environment locally so Checkov dependencies do not alter the monitor's application environment:

```powershell
py -3.12 -m venv .superpowers/checkov-venv
.\.superpowers\checkov-venv\Scripts\python.exe -m pip install -r requirements-security.txt
.\.superpowers\checkov-venv\Scripts\python.exe -m pytest tests/test_security_scan.py -q
.\.superpowers\checkov-venv\Scripts\python.exe security/scan.py
```

The `.superpowers/` directory is ignored by Git; do not force-add the environment or reports. Checkov runs offline without downloading Terraform modules or contacting an optional platform; the dependency installation itself requires network access.

The initial repository scan reported 152 passed, 20 failed, and 0 skipped checks. After two local bootstrap remediations, the latest scan remains **not passing**: 154 passed, 18 failed, and 0 skipped checks. The seven-day incomplete-upload abort setting and removal of global alarm-read permission are code changes only; they require a new reviewed bootstrap plan and explicit live-change approval. The already applied dashboard-only IAM record does not approve these later changes. Consult [the security review](security-review.md) before proceeding. Some remaining findings require meaningful cost, retention, encryption-key, or architecture decisions. Do not add a blanket skip, soft-fail mode, broad IAM permissions, or paid infrastructure to obtain a green badge. Adding the workflow does not by itself configure a required branch-protection check.

Review raw artifacts before sharing: scans can contain source snippets, resource identifiers, and local paths. Keep credentials, personal addresses, and backend configuration out of tracked Terraform so CI artifacts do not expose them.

## Bounded incident demonstration

For the current paused deployment, follow [the acceptance evidence and procedure](acceptance-evidence.md). The approved manual demonstration invokes the existing Lambda at most five times using one unique lab ID, leaves the `demo` item and Scheduler input untouched, and ends the lab state at `UP`.

The failure injection changes the lab's expected HTTP status to `503` while `https://example.com` still returns `200`; it tests failure classification and state transitions, not a real external-site outage. The original expected status `200` restores the lab. Existing subscribers receive the normal outage and recovery notifications. Do not retry an ambiguous invocation blindly: inspect its state, history, and logs first.

This is a direct Lambda integration test, not evidence that the disabled Scheduler ran. Lab rows become eligible for TTL deletion after seven days; no manual table deletion or resource teardown is required.

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
