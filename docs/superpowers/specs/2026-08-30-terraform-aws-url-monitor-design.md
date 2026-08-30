# Terraform AWS URL Monitor — Design

## Summary

Build a small but production-shaped URL availability monitor on AWS. Terraform provisions and operates the complete service. Amazon EventBridge invokes a Lambda function every five minutes, the function checks configured URLs, DynamoDB records the latest state, and SNS sends email only when a target changes between healthy and unhealthy.

The project is deliberately sized for seven one-hour sessions. It must remain useful after the learning exercise, demonstrate practical Terraform operations in a portfolio, and keep ongoing AWS costs very low.

## Goals

- Monitor up to five public HTTP or HTTPS endpoints every five minutes.
- Detect HTTP errors, DNS failures, TLS failures, and request timeouts.
- Alert only after two consecutive failures to reduce transient noise.
- Send one outage notification and one recovery notification per state transition.
- Provision application infrastructure, permissions, logging, alerting, remote state, and GitHub deployment automation with Terraform.
- Use short-lived GitHub OIDC credentials instead of stored AWS access keys.
- Validate changes in CI and require a human approval before applying an exact saved plan.
- Provide a repeatable incident demonstration using a known-good URL and the reserved `.invalid` domain.

## Non-goals

- A public status page or historical analytics dashboard.
- Browser rendering, JavaScript execution, authenticated endpoints, or response-body assertions.
- Multi-region checks, sub-minute checks, or high-volume monitoring.
- Slack, Teams, SMS, or mobile push notifications.
- VPC networking, EC2, containers, load balancers, or a custom domain.
- Multiple AWS environments or accounts in the first version.

## Architecture

The runtime path is:

```text
EventBridge schedule
        |
        v
Lambda URL checker -----> CloudWatch Logs
        |
        v
DynamoDB current state
        |
        +---- state transition ----> SNS topic ----> confirmed email subscriber

Lambda execution errors ----> CloudWatch alarm ----> SNS topic
```

The delivery path is:

```text
Developer -> GitHub pull request -> validation CI
Developer -> manual deploy run -> Terraform plan -> production approval -> exact plan apply
                                      |                                  |
                                      +------ GitHub OIDC roles ----------+
                                                        |
                                                        v
                                              versioned S3 state + lock
```

The AWS region is `ap-northeast-2`. Lambda does not run in a VPC, avoiding NAT Gateway cost and unnecessary network dependencies.

## Repository Layout

```text
bootstrap/
  backend and GitHub OIDC Terraform configuration
infra/
  root Terraform configuration for the live monitor
modules/url-monitor/
  reusable monitor module
lambda/
  Python URL-checking handler
tests/
  Python unit tests
infra/tests/
  Terraform tests with mocked AWS providers
.github/workflows/
  pull-request validation and approved deployment workflows
docs/
  architecture, operating guide, incident demonstration, and cost notes
```

`bootstrap` creates the versioned S3 state bucket, public-access blocks, server-side encryption, the GitHub OIDC provider, separate plan and deploy roles, and a USD 5 monthly AWS Budget notification. It is applied once from a non-root local AWS CLI session. After bucket creation, the bootstrap state is migrated into the same S3 backend under a separate key.

`infra` uses the S3 backend with `use_lockfile = true`. The state bucket is intentionally independent of the monitor module so destroying the monitor cannot erase its own state storage.

## Terraform Inputs

The root module accepts these required or validated inputs:

- `project_name`: resource-name and tag prefix; defaults to `url-monitor`.
- `alert_email`: required email address for SNS subscription and budget notifications.
- `monitor_targets`: map of one to five target objects.
- `schedule_expression`: defaults to `rate(5 minutes)`.
- `failure_threshold`: defaults to `2` and must be at least one.
- `log_retention_days`: defaults to `7`.

Each target object contains:

- `url`: public HTTP or HTTPS URL.
- `expected_statuses`: non-empty set of acceptable HTTP status codes; defaults to `200` when omitted by the root configuration.
- `timeout_seconds`: request timeout between one and five seconds; defaults to five.

The starter configuration monitors `https://example.com`. A failure demonstration temporarily changes this value to `https://monitor-demo.invalid`, where `.invalid` is reserved for guaranteed invalid-domain testing.

## Runtime Components

### EventBridge

One schedule invokes the Lambda function every five minutes. The schedule passes the configured target set as an event payload. Terraform grants EventBridge permission to invoke only this Lambda function.

### Lambda

The Python handler uses the standard library HTTP client so the deployment package has no runtime dependencies. It checks targets sequentially and isolates each target in its own exception boundary, ensuring one bad endpoint does not stop the remaining checks.

The function timeout is 30 seconds, which covers five targets with per-request timeouts capped at five seconds. Reserved concurrency is one because overlapping monitor executions are unnecessary. Logs include monitor name, result, response code or error category, elapsed milliseconds, and transition outcome. Logs never include AWS credentials or Terraform state.

### DynamoDB

An on-demand table uses `monitor_id` as its partition key. Each item stores:

- `status`: `UP`, `PENDING_DOWN`, or `DOWN`.
- `consecutive_failures`.
- `checked_at`.
- `last_changed_at`.
- `response_ms` when a response was received.
- `last_error` when a check failed.
- `expires_at`, refreshed on every check, for automatic cleanup of removed targets.

The table stores only the latest state, not an event history. DynamoDB TTL removes a target item seven days after that target is removed from the configuration. Point-in-time recovery is excluded because the data is disposable and automatically rebuilt by subsequent checks.

### SNS

One topic carries outage, recovery, and Lambda-error notifications. The email subscription requires the recipient to click AWS's confirmation link after the first deployment. The operating guide treats an unconfirmed subscription as an incomplete deployment. The bootstrap budget sends directly to the same email address because it exists before the runtime SNS topic.

### CloudWatch

The Lambda log group is managed explicitly with seven-day retention. A CloudWatch alarm monitors Lambda execution errors and publishes to the SNS topic. Custom availability metrics and dashboards are excluded from version one to avoid extra cost and scope.

## State Machine

For a target with no existing DynamoDB item:

- A successful check creates `UP` without sending an email.
- A failed check creates `PENDING_DOWN` with `consecutive_failures = 1` without sending an email.

For an `UP` or `PENDING_DOWN` target:

- A successful check sets `UP`, clears the failure count, and sends no email.
- A failed check increments the count.
- Reaching the configured threshold changes the state to `DOWN` and sends one outage email.

For a `DOWN` target:

- Another failed check updates diagnostic fields but sends no email.
- A successful check changes the state to `UP`, clears the failure count, and sends one recovery email.

An alert includes target name, URL, previous and new state, UTC timestamp, response code or error category, and response time when available.

## Error Handling

The handler classifies failures as HTTP status mismatch, DNS resolution failure, TLS failure, timeout, connection failure, or unexpected internal error. Target-level network failures participate in the two-failure state machine. An unexpected error for one target is logged and does not abort other target checks.

For a state transition, the function publishes the SNS message before committing the new state. If publishing fails, the old state remains and the transition is retried. If publishing succeeds but the subsequent DynamoDB write fails, a retry can produce a duplicate email; delivery is therefore at-least-once during infrastructure failures. Normal scheduled checks do not repeat alerts after a successful state update.

Target processing continues after an internal error so the remaining endpoints are still checked. After all targets finish, any collected internal error causes the invocation to fail, incrementing the Lambda `Errors` metric and triggering the CloudWatch alarm. The reserved concurrency and five-minute interval prevent overlapping normal executions.

Terraform variable validation rejects empty target maps, more than five targets, non-HTTP(S) URLs, empty expected-status sets, and request timeouts outside the supported range.

## Security

- Root AWS credentials and root access keys are never used.
- Local bootstrap runs through an authenticated non-root AWS CLI profile.
- GitHub stores no long-lived AWS credentials.
- The plan-role trust policy accepts only the selected repository's `main` branch; the deploy-role trust policy accepts only that repository's `production` environment.
- The plan role is read-only for managed services except for the minimum S3 state and lock operations.
- The deploy role is limited to the AWS services and project-name prefix used by this project, including tightly scoped `iam:PassRole` access for the Lambda execution role.
- The Lambda execution role can write its logs, read and update only its DynamoDB table, and publish only to its SNS topic.
- The state bucket blocks all public access, enables versioning and server-side encryption, and grants access only to the local operator and GitHub roles.
- Sensitive values and Terraform state files are excluded from Git. The alert email is declared sensitive, provided through an uncommitted variable file locally, and stored as an encrypted GitHub Actions repository secret. The `production` environment separately protects the apply job with required approval.

## CI/CD

### Pull-request validation

Every pull request runs without AWS credentials and performs:

- `terraform fmt -check`.
- Terraform initialization without the remote backend.
- `terraform validate`.
- `terraform test` with mocked AWS providers.
- TFLint static checks.
- Python unit tests.

### Approved deployment

A manual workflow on the `main` branch performs:

1. Assume the read-only plan role through GitHub OIDC.
2. Initialize the S3 backend and acquire its lock.
3. Create a saved Terraform plan.
4. Publish the redacted human-readable plan to the workflow summary and retain the sensitive binary plan artifact for one day, accessible only through the repository's Actions permissions.
5. Wait for approval on the GitHub `production` environment.
6. Assume the deploy role through GitHub OIDC.
7. Download and apply the exact saved plan.

The workflow does not automatically apply pull requests or ordinary pushes. Destruction uses the same manual and approved workflow with an explicit destroy input.

## Testing and Acceptance

Python unit tests mock HTTP, DynamoDB, and SNS interactions and cover:

- Initial healthy check.
- First failure without alert.
- Second consecutive failure with one outage alert.
- Continued failure without duplicate alerts.
- Recovery with one recovery alert.
- DNS, TLS, timeout, connection, and unexpected-error handling.
- One failed target not interrupting another target.

Terraform checks cover formatting, validation, variable constraints, and provider-independent module structure. CI must pass before merge.

The end-to-end acceptance demonstration is:

1. Deploy with `https://example.com` and confirm the SNS subscription.
2. Observe two healthy scheduled executions and an `UP` DynamoDB item.
3. Change the target to `https://monitor-demo.invalid` through the approved workflow.
4. Receive one outage email after two failed checks in the normal execution path.
5. Observe additional scheduled failures without another outage email.
6. Restore `https://example.com` through the approved workflow.
7. Receive one recovery email in the normal execution path.
8. Confirm Lambda logs, DynamoDB state, GitHub plan output, and Terraform remote state.

The project is complete when all automated checks pass and the full outage-and-recovery demonstration succeeds.

## Cost Controls

- No EC2, VPC NAT Gateway, load balancer, RDS, custom domain, or public IPv4 address.
- Lambda runs only on the five-minute schedule.
- DynamoDB uses on-demand capacity and stores at most five small items.
- CloudWatch log retention is seven days.
- S3 stores only small Terraform state and lock objects.
- A USD 5 monthly budget notification is created during bootstrap.
- Every resource receives project and environment tags where the AWS service supports tags.

The README will explain that AWS pricing and free-tier eligibility can change and will link to the current AWS billing console. It will also provide a resource inventory and an approved destroy procedure.

## Seven-session Delivery Scope

1. Initialize the repository, local toolchain, tests, and bootstrap configuration.
2. Create the S3 backend, budget, GitHub OIDC provider, and scoped roles.
3. Implement the Lambda state machine with unit tests.
4. Build the reusable Terraform monitor module and package the function.
5. Add EventBridge, DynamoDB, SNS, logs, alarms, and deploy the first version.
6. Add GitHub validation and approved deployment workflows.
7. Run the outage/recovery demonstration, verify costs and resources, and finish the operating README.

If a session runs long, historical dashboards and additional endpoints remain excluded; none of the core acceptance criteria are removed.
