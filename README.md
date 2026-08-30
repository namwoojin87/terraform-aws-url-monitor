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

```text
EventBridge Scheduler (5 minutes)
             |
             v
        Lambda checker ─────> DynamoDB state
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
- Credential-free pull-request validation
- Saved-plan delivery with encrypted plan artifacts and production approval
- Stateful outage suppression and recovery notifications
- Least-privilege runtime IAM for the Lambda and Scheduler components
- Short log retention and a monthly cost-budget notification

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

## Cost controls

The design intentionally excludes VPC networking, NAT Gateway, EC2, load balancers, database servers, public IPv4 addresses, custom metrics, and dashboards. DynamoDB is on-demand, Lambda has modest memory and a 30-second timeout, logs retain seven days, and the account has a verified USD 5 monthly budget notification.

## Repository layout

- `bootstrap/` — remote state, budget, and GitHub OIDC roles
- `infra/` — production Terraform root and target configuration
- `modules/url-monitor/` — reusable URL-monitor Terraform module
- `lambda/url_monitor/` — tested Python monitoring handler
- `.github/workflows/` — validation and approved deployment workflows
- `docs/runbook.md` — operating and teardown guidance
