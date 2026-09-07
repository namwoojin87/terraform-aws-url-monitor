# Terraform AWS URL Monitor

A low-cost, serverless monitor for one to five public HTTP(S) endpoints. Terraform provisions the runtime; GitHub Actions creates a reviewed saved plan and requires production approval before applying it.

## Verified behavior

The acceptance run used the actual five-minute Scheduler path and demonstrated the complete state sequence:

`UP` → `PENDING_DOWN` → `DOWN` → `UP`

- The second failed check logged `transition=OUTAGE`.
- A third failed scheduled check remained `DOWN`; SNS had published only one message.
- After the reviewed restoration to `https://example.com`, the next scheduled check logged `transition=RECOVERY`.
- SNS metrics then reported two messages published and two notifications delivered in total: one outage and one recovery.

This confirms two consecutive failures are required for an outage, continued failures do not repeat normal outage notifications, and a later success produces one recovery notification.

## Architecture

This is the runtime view. The [full architecture](docs/architecture.md) also shows credential-free CI, OIDC plan/apply roles, protected deployment approval, encrypted plan artifacts, remote state, drift detection, and cost controls. It labels new local changes separately from deployed services.

```text
EventBridge Scheduler (5 minutes)
             |
             v
        Lambda checker ─────> DynamoDB current state
             |
             +──────────────> DynamoDB 7-day check history
             |
             +──────────────> SNS notifications
             |
             +──────────────> CloudWatch Logs and error alarm
```

The Lambda handles targets sequentially, records the current state by stable target key, and sends notifications only on state transitions. Its 30-second maximum runtime is much shorter than the five-minute schedule interval, which bounds normal scheduled overlap. It deliberately uses account unreserved concurrency so it works in low-quota accounts.

## What it demonstrates

- Reusable Terraform module with validated target inputs
- Encrypted, versioned S3 Terraform state with native locking
- GitHub OIDC roles instead of long-lived AWS keys
- Queryable per-target check history with automatic seven-day expiry
- Credential-free pull-request validation
- Saved-plan delivery with encrypted plan artifacts and production approval
- Stateful outage suppression and recovery notifications
- Least-privilege runtime IAM for the Lambda and Scheduler components
- Short log retention and a monthly cost-budget notification
- Weekly infrastructure drift checks with a sanitized GitHub Actions summary

## Monitoring and security extension status

The current extension adds Terraform code for an optional private CloudWatch operations dashboard and a credential-free Checkov workflow. [Draft PR #8](https://github.com/namwoojin87/terraform-aws-url-monitor/pull/8) is published; its initial CI succeeded and its actual security scan failed on 18 findings, with evidence uploaded. **The dashboard remains undeployed.** The exact dashboard-scoped bootstrap permission update was approved, applied, and verified on 2026-09-07; see [the IAM verification record](docs/dashboard-iam-change.md). The protected runtime deployment remains pending; the Scheduler remains disabled.

The initial full security scan found **152 passed checks, 20 failed checks, and no skipped checks** across 30 resources. Two earlier local bootstrap fixes reduced that to 18 findings. The fresh hardening scan now evaluates **37 resources: 195 passed, 16 failed, 0 skipped, 0 parsing errors**. Five previous findings are fixed, while the new KMS account-delegation policy produces three additional findings requiring context/owner review. The gate still fails and no exceptions have been approved. All new bootstrap/runtime settings remain unapplied. See the [security review](docs/security-review.md) for exact findings and the distinction between provider-managed encryption and customer-managed keys.

Fresh local verification on 2026-09-07 passed **71 Python tests**, **11 module and 9 bootstrap Terraform mock tests**, Terraform format/validate, TFLint and whitespace checks. The full repository security scan exited `1` with 16 unresolved findings; passing the gate's tests does not mean the infrastructure passed the scan. See [the hardening verification record](docs/hardening-verification-2026-09-07.md) for exact commands, timestamps and pending deployment boundaries. The earlier single invocation of the existing AWS checker returned HTTP 200 / UP with matching state/history records and Scheduler disabled; [that earlier live evidence](docs/final-verification.md) does not verify the new encrypted publisher paths.

The [acceptance evidence](docs/acceptance-evidence.md) records a separate, bounded manual drill against the deployed Lambda and DynamoDB tables. It distinguishes actual results from planned dashboard and CI verification. This drill does not enable the Scheduler or change the production target.

### Recovery and encrypted alert extension — not deployed

The approved hardening branch adds PITR for both tables, separate SSE-SQS queues for Scheduler delivery failures and Lambda execution failures, Active tracing, a 20-series dashboard, and one bootstrap-owned SNS encryption key. Lambda code-error retries are zero with a 300-second event age; Scheduler delivery retries remain 300 seconds / one retry. No queue consumer, automatic replay, concurrency reservation or additional network infrastructure is introduced.

The SNS key is managed in `bootstrap/`; runtime resolves `alias/url-monitor-alerts`, grants Lambda scoped key use, and restricts the CloudWatch grant to the project alarm. The key policy also delegates account IAM administration, so it is not an exclusive publisher allowlist. Bootstrap must be reviewed/applied before runtime can plan against that alias. The existing dashboard-only IAM approval does not approve these new key and permission changes. See the [recovery runbook](docs/recovery-runbook.md), [SNS encryption runbook](docs/sns-encryption-runbook.md) and [approved scope](docs/superpowers/specs/2026-09-07-low-cost-hardening.md). None of the earlier live notification evidence verifies these new encrypted publisher paths.

## Setup

1. Create or select the AWS account intended for the monitor in `ap-northeast-2` (Seoul); use a non-root administrative identity for bootstrap operations.
2. Apply the reviewed `bootstrap/` configuration, migrate its state to the configured backend, and record its outputs only in the approved GitHub repository configuration.
3. Set these GitHub repository variables from the reviewed bootstrap outputs: `AWS_ACCOUNT_ID`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, and `AWS_DEPLOY_ROLE_ARN`.
4. Generate an age key pair locally in a new, protected directory outside the repository. The following PowerShell example uses a task-specific directory under `LOCALAPPDATA` and fails rather than replacing an existing directory or identity file:

   ```powershell
   $keyDirectory = Join-Path $env:LOCALAPPDATA 'url-monitor\age'
   New-Item -ItemType Directory -Path $keyDirectory -ErrorAction Stop | Out-Null
   $identityFile = Join-Path $keyDirectory 'tf-plan-age-identity.txt'
   age-keygen -o $identityFile
   age-keygen -y $identityFile
   ```

   Copy only the public recipient printed by the final command into the `TF_PLAN_AGE_RECIPIENT` repository variable. Transfer the matching private identity directly through a controlled secret-entry process to `TF_PLAN_AGE_IDENTITY` in the protected `production` environment. Never print, log, commit, or route the private identity through shell history.
5. Keep a secure, access-controlled backup of the private identity outside the repository. For rotation, do not leave an in-flight saved plan: coordinate the new repository variable and production secret, verify a new deployment, allow the prior one-day plan artifacts to expire, then remove temporary local copies and any superseded backup according to the key-retention policy.
6. Set `ALERT_EMAIL` as a GitHub repository secret.
7. Configure the `production` environment with deployment protection and required review.
8. Confirm the SNS email subscription after the first runtime deployment.
9. Run `Terraform Deploy` manually with `apply`, review its saved plan, and approve the protected apply job.

Do not commit an alert address, backend configuration values, state, plan files, credentials, or private key material. Local Terraform inputs belong in untracked files or environment variables.

## Operate the monitor

The committed demonstration target is `https://example.com` under the stable `demo` key. See [the operating runbook](docs/runbook.md) for target changes, state/log inspection, alert troubleshooting, and teardown procedures.

`infra/monitor.auto.tfvars.json` keeps `schedule_enabled` set to `false`. Scheduled checks remain paused until a reviewed pull request deliberately changes it to `true` and the approved Terraform deployment applies that change.

`Terraform Drift Check` runs every Monday at approximately 09:17 Korea time and can be started manually from `main`. It compares AWS with Terraform and reports external drift separately from proposed configuration changes. A difference or execution error fails the workflow for visibility; it never applies repairs or enables URL checks. See [the drift-check runbook](docs/runbook.md#weekly-infrastructure-drift-check) for interpretation and notification settings.

## Cost controls

The design intentionally excludes VPC networking, NAT Gateway, EC2, load balancers, database servers, public IPv4 addresses, and custom metrics. DynamoDB is on-demand: the state table remains tiny, and each enabled target writes 288 small history items per day that become eligible for automatic deletion after seven days.

The updated optional operations dashboard uses 20 existing metric series, without log queries, custom metrics, or public sharing. CloudWatch lists a free allowance of three custom dashboards with up to 50 metrics each; check the account's total usage before deployment. Additional dashboards and underlying AWS activity may incur charges, even while the Scheduler is paused. See [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) and the [dashboard runbook](docs/runbook.md#operations-dashboard).

Once deployed, the one customer-managed SNS key has initial storage cost of USD 1/month, plus requests and tax; the first two rotations each add USD 1/month storage. Runtime deletion or Scheduler OFF does not delete the bootstrap key or stop its storage charges. PITR, SQS and tracing also have usage-based costs; this is not a zero-cost or USD 5-total guarantee. See [KMS pricing](https://aws.amazon.com/kms/pricing/) and the lifecycle boundary in the encryption runbook. No new key or chargeable runtime resource was created during local hardening verification.

## Repository layout

- `bootstrap/` — remote state, budget, and GitHub OIDC roles
- `infra/` — production Terraform root and target configuration
- `modules/url-monitor/` — reusable URL-monitor Terraform module
- `lambda/url_monitor/` — tested Python monitoring handler
- `.github/workflows/` — validation and approved deployment workflows
- `docs/runbook.md` — operating and teardown guidance
- `docs/architecture.md` — runtime, delivery, security, and cost-control architecture
- `docs/acceptance-evidence.md` — verification scope and sanitized demonstration results
- `docs/security-review.md` — current findings and decisions still requiring review
- `security/` — strict Checkov gate; local raw reports are ignored by Git
