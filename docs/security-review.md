# Terraform security review

The `Terraform Security` workflow runs a full Terraform scan on pull requests, pushes to `main`, and manual dispatch. It is published in draft PR #8 and its [first actual GitHub run](https://github.com/namwoojin87/terraform-aws-url-monitor/actions/runs/34091253763) failed with 154 passed / 18 failed / 0 skipped checks, while summary publication and evidence upload succeeded. That is historical remote evidence, not the result of the newer local hardening work below. Adding the scanner or fixing some findings does not approve a risk exception or make this deployment compliant with a security standard. See [the earlier execution record](final-verification.md) for its exact commit and live-invocation scope.

## Evidence and scope

Checkov **3.3.16**, Python **3.12**, local verification on **2026-09-07**:

| Input | Native scanner exit | Gate exit | Result |
| --- | --- | --- | --- |
| Repository after SNS encryption and reliability hardening (`a0a5464`), fresh run at 2026-09-07T08:11:18Z | 1 | 1 | **37 resources; 195 passed; 16 failed; 0 skipped; 0 parsing errors** |
| Repository after reliability hardening (`2f9ae9d`), including bootstrap, runtime root and local module | 1 | 1 | 33 resources; 158 passed checks; 14 failed; 0 skipped; 0 parsing errors |
| Repository after earlier local bootstrap remediation (`583c6a5`) | 1 | 1 | 30 resources; 154 passed checks; 18 failed; 0 skipped; 0 parsing errors |
| Repository Terraform before local bootstrap remediation | 1 | 1 | 30 resources; 152 passed checks; 20 failed; 0 skipped; 0 parsing errors |
| Deliberately public S3 bucket in a temporary directory | 1 | 1 | 3 passed; 8 failed, including `CKV_AWS_20` on `aws_s3_bucket.public` |
| Encrypted SNS topic fixture | 0 | 0 | Evaluated checks pass |
| Empty temporary directory | 0 | 2 | Rejected: no resources evaluated |
| Malformed Terraform fixture | 0 | 2 | Rejected: parsing error |
| SNS encryption check suppressed inline | 0 | 1 | Rejected: unapproved skipped check |

The five fixture tests execute the actual scanner through the same gate used in CI. They first failed before the runner existed. The malformed and empty cases matter because Checkov's native zero exit code is insufficient evidence of a complete scan. The repository counts are a dated working-tree snapshot; each CI artifact records that run's current counts.

Six additional regression cases exercise missing finding fields, wrong finding types, and null paths for scanner exit codes 0 and 1. These mock only the external scanner boundary: the real gate must retain raw evidence, write ERROR, return 2, and never announce PASSED. Tests were observed failing before their fixes, then all six passed. The earlier complete suite had 70 tests; the hardening work adds one key-lifecycle check, and the fresh complete suite passed **71 tests** without skips. Verdict selection occurs after evidence rendering, and handled report errors explicitly select exit 2. The [hardening verification record](hardening-verification-2026-09-07.md) separates these functional results from the still-failing security scan.

The scanner reads all Terraform under the repository, resolves its local module, and uses its complete bundled Terraform ruleset. Checkov's default exclusions cover hidden directories and `.terraform`; there is no check allowlist, severity filter, baseline, or suppression list. External module downloads and Prisma Cloud downloads/uploads are disabled. Future external modules will require an explicit coverage decision because they are not downloaded. This source scan does not inspect live AWS state, test runtime permissions, perform dependency or secret scanning, or prove alert delivery.

The job requests only `contents: read`, does not obtain AWS credentials or an OIDC token, and does not run Terraform apply. The scanner and pytest versions are pinned in `requirements-security.txt`; transitive Python dependencies remain subject to those packages' version constraints. Action references are immutable full commit SHAs verified against upstream release tags on the review date. This uses open-source Checkov and standard GitHub Actions execution/artifact storage; no paid security service is enabled.

Every completed scan writes `security/reports/checkov.json` (original scanner output), `checkov.log` (diagnostics), and `summary.md` (counts, exit code, findings, and gate decision). CI publishes the summary and uploads `terraform-security-evidence` even if the scan fails, retaining it for 14 days. Setup or fixture-test failures produce an explicit unavailable-evidence summary and a failed job. Reports can contain Terraform source, so review them before sharing them outside the repository's access boundary. Generated local reports are ignored by Git.

## Remediated bootstrap findings — applied and verified

The following changes were separately approved, applied and directly verified on AWS on **2026-09-07 at 09:04:34 UTC**. The full post-apply bootstrap plan reported no changes; see the [bootstrap apply record](bootstrap-hardening-apply-2026-09-07.md). This new evidence supersedes the earlier local-only status; the historical dashboard-only IAM record did not prove these settings were active. Source scans no longer report either resource/check pair below, but the 16 remaining findings keep the gate red. Approval of the bootstrap change, including its KMS account-IAM delegation, did not approve scanner exceptions or runtime deployment.

| Check | Exact Terraform scope | Applied remediation |
| --- | --- | --- |
| `CKV_AWS_300` | `bootstrap/main.tf`: `aws_s3_bucket_lifecycle_configuration.state` | The existing enabled rule now aborts incomplete multipart uploads after seven days while retaining 90-day expiration for noncurrent completed versions. AWS documents this as cleanup of incomplete upload parts; it does not delete completed state objects. See [aborting incomplete multipart uploads with a lifecycle configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpu-abort-incomplete-mpu-lifecycle-config.html). |
| `CKV_AWS_356` | `bootstrap/oidc.tf`: `aws_iam_policy_document.deploy` | `cloudwatch:DescribeAlarms` was removed only from the `Resource = "*"` statement and remains available on `arn:aws:cloudwatch:ap-northeast-2:<account-id>:alarm:<project-name>-*`. AWS lists alarm as a supported resource type for this action. See [CloudWatch permissions and supported resources](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudwatch.html). |

## Local runtime remediations — not deployed

The approved hardening work enables both PITR settings, separates Scheduler delivery failures from Lambda execution failures, and enables Active tracing. The reliability-stage full scan (`2f9ae9d`) no longer reports the four resource/check pairs below. Its two new SSE-SQS queues also passed `CKV_AWS_27`, `CKV_AWS_168` and `CKV2_AWS_73` each. This is source evidence, not a restoration drill, runtime permission test or proof of queue delivery. See the [manual recovery runbook](recovery-runbook.md).

| Check | Exact Terraform address | Code change |
| --- | --- | --- |
| `CKV_AWS_26` | `module.url_monitor.aws_sns_topic.alerts` | Uses the bootstrap-owned SNS customer-managed key. Lambda key use is scoped to the exact key/SNS service/topic; CloudWatch grants are scoped to the exact account/alarm/topic. The final scan passes this check; both encrypted publisher paths still require live verification. |
| `CKV_AWS_28` | `module.url_monitor.aws_dynamodb_table.state`; `module.url_monitor.aws_dynamodb_table.history` | PITR enabled on both existing tables; on-demand billing and seven-day TTL retained. Actual restoration needs a separately approved new table and recovery plan. |
| `CKV_AWS_116` | `module.url_monitor.aws_lambda_function.checker` | Dedicated execution DLQ with 14-day SSE-SQS retention; unqualified async age 300 seconds / zero code-error retries. Scheduler uses a distinct delivery DLQ and retains its 300/1 delivery retry policy. No automatic replay or exactly-once claim. |
| `CKV_AWS_50` | `module.url_monitor.aws_lambda_function.checker` | Active tracing with two required write actions. This is sampled Lambda tracing, not instrumentation of every outbound call. |

## Proposed exceptions for owner review

Every row below is **proposed, not approved, and not applied to the gate**. The final scan has 16 exact resource/check findings: 13 remaining from the previous design and three new KMS policy-document findings. An existing cost or operating constraint explains a finding; it does not silently accept its residual risk. Runtime addresses include the `module.url_monitor` prefix reported by the full-root scan. The table-encryption row covers exactly the two listed addresses, not every DynamoDB table.

| Check | Exact resource address | Existing design, residual risk, and review trigger |
| --- | --- | --- |
| `CKV_AWS_109`, `CKV_AWS_111`, `CKV_AWS_356` | `bootstrap/alerts-encryption.tf`: `aws_iam_policy_document.alerts_key` (policy attached to `aws_kms_key.alerts`) | Three findings on the `EnableAccountIAMPermissions` statement (`kms:*`). AWS's default account-root pattern enables IAM delegation for this key; `Resource = "*"` in a KMS key policy denotes the attached key, not every account resource. Account/IAM administrators remain trusted and can delegate access. Review the generic IAM-document checks in this KMS context, without declaring an approved exception or weakening administrator recovery. Direct deploy KMS rights remain exact-key `DescribeKey`. Revisit on administrator/IAM ownership or key-policy changes. |
| `CKV_AWS_119` | `module.url_monitor.aws_dynamodb_table.state`; `module.url_monitor.aws_dynamodb_table.history` | AWS-owned encryption is used instead of customer-managed keys. Data remains encrypted, but the project lacks customer key-policy control and KMS audit capabilities. Revisit before storing sensitive data or requiring customer key control. |
| `CKV_AWS_158` | `module.url_monitor.aws_cloudwatch_log_group.checker` | CloudWatch's default at-rest encryption is used without a customer-managed KMS key. Residual risk is absence of customer key control, not plaintext log storage. Revisit for sensitive log contents or key-control requirements. |
| `CKV_AWS_338` | `module.url_monitor.aws_cloudwatch_log_group.checker` | Seven-day retention is intentional. Investigation evidence older than that is unavailable; no one-year audit retention is provided. Revisit when incident or audit requirements exceed seven days. |
| `CKV_AWS_272` | `module.url_monitor.aws_lambda_function.checker` | The zip deployment has a content hash and a protected deployment workflow, but no Lambda code-signing enforcement. A trusted deployment principal can deploy unsigned code. Revisit if signed artifacts become a requirement. |
| `CKV_AWS_173` | `module.url_monitor.aws_lambda_function.checker` | Environment values are resource identifiers; Lambda encrypts them at rest by default. No customer-managed key controls are configured. Revisit before storing secrets in environment variables. |
| `CKV_AWS_115` | `module.url_monitor.aws_lambda_function.checker` | Existing design uses account unreserved concurrency to support low-quota accounts. A 30-second timeout and five-minute schedule limit ordinary overlap, but do not cap manual/duplicate invocations or isolate capacity. Revisit after quota changes or if concurrent invocation becomes material. |
| `CKV_AWS_117` | `module.url_monitor.aws_lambda_function.checker` | The monitor checks public HTTP(S) endpoints and intentionally has no customer VPC. There are no customer VPC egress controls; adding a VPC would require an internet-egress design. Revisit for private targets or enforced network boundaries. |
| `CKV_AWS_297` | `module.url_monitor.aws_scheduler_schedule.monitor` | Scheduler uses its default AWS-owned encryption without customer key control. Revisit if schedule input becomes sensitive or customer-managed encryption is required. |
| `CKV2_AWS_62` | `bootstrap/main.tf`: `aws_s3_bucket.state` | No S3 event notification pipeline is configured. State-object changes do not create an independent event notification. Revisit when change-detection requirements require one. |
| `CKV_AWS_18` | `bootstrap/main.tf`: `aws_s3_bucket.state` | No S3 server-access log destination is configured. Bucket access-log evidence is unavailable; this scan does not establish whether any account-level logging covers it. Revisit for access-audit requirements. |
| `CKV_AWS_144` | `bootstrap/main.tf`: `aws_s3_bucket.state` | Versioning is enabled, but no cross-region replica exists. A regional loss or inaccessible bucket can impede Terraform recovery. Versioning is not a cross-region backup. Revisit if a regional recovery objective is adopted. |
| `CKV_AWS_145` | `bootstrap/main.tf`: `aws_s3_bucket.state` | Explicit SSE-S3 `AES256` encryption is configured instead of KMS. State remains encrypted, but customer KMS key controls are absent. State can contain sensitive values; this exception requires explicit review. |

An approved exception should identify the exact file, resource address and check ID, owner, reason, residual risk, approval date, expiry or review date, and compensating controls. It must remain visible in raw evidence. Do not add broad `--skip-check`, `--soft-fail`, `continue-on-error`, or a blanket baseline to turn these results green. Until reviewed exceptions or fixes are implemented, this job remains red; branch-protection changes are not included in this work.

## Interpreting encryption findings

AWS documents default encryption for [DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/encryption.usagenotes.html), [CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/data-protection.html), [Lambda environment variables](https://docs.aws.amazon.com/lambda/latest/dg/security-encryption-at-rest.html), and [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/encryption-rest.html). Those findings concern customer-managed key controls. They should not be described as proof that these services store this project's data in plaintext.

The last deployed runtime snapshot did not configure SNS KMS SSE. The approved hardening code now does, and the fresh scan passes `CKV_AWS_26`; runtime AWS application and both publisher tests remain pending. AWS states that [SNS uses disk encryption by default and KMS adds another access-control layer](https://docs.aws.amazon.com/securityhub/latest/userguide/sns-controls.html#sns-1), so the previous finding was not proof of plaintext storage. [CloudWatch encrypted-SNS compatibility](https://repost.aws/knowledge-center/cloudwatch-configure-alarm-sns) and [publisher key permissions](https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html) informed the one customer-managed key design; simply using `alias/aws/sns` would not preserve the required policy control.

The three new KMS findings concern the standard account-root IAM-delegation statement, not the constrained CloudWatch statement. [AWS's default key-policy semantics](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html) and [key-policy elements](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-overview.html) explain its account principal and key-local `Resource = "*"`. This is a context review, not an automatic false-positive dismissal: account administrator trust is a residual risk, and no exception has been approved. The data source remains visible to Checkov; no refactor or meaningless condition was added to hide the findings.

For the VPC finding, [AWS's internet-access guidance](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc-internet.html) confirms that Lambda has internet access by default; a customer VPC requires additional routing and egress configuration. The current public-endpoint monitor deliberately avoids that infrastructure.

Checkov's documented [failure behavior](https://www.checkov.io/2.Basics/Hard%20and%20soft%20fail.html) and [CLI options](https://www.checkov.io/2.Basics/CLI%20Command%20Reference.html) inform the scanner configuration. The fixture evidence above records the installed version's actual behavior where a native exit code alone is insufficient.

## Reproduce locally

Use an isolated environment so Checkov's dependencies do not replace the application's development dependencies:

```powershell
python -m venv .superpowers/checkov-venv
.superpowers/checkov-venv/Scripts/python.exe -m pip install -r requirements-security.txt
.superpowers/checkov-venv/Scripts/python.exe -m pytest tests/test_security_scan.py tests/test_security_scan_errors.py -q
.superpowers/checkov-venv/Scripts/python.exe security/scan.py
```

On Linux, use `.superpowers/checkov-venv/bin/python` for the last three commands. Exit `0` means all evaluated checks passed with none skipped; `1` means unresolved findings/skips; `2` means an incomplete or invalid scan. The regular application test environment skips the five security integration tests when Checkov is not installed; the dedicated security job installs it and executes them.
