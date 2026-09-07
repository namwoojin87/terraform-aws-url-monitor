# SNS alert encryption runbook

## Deployment status and order

This repository contains code awaiting deployment. The SNS customer-managed key, alias, publisher policies, and encrypted topic have not been verified live.

Deployment has two separately approved stages:

1. Obtain explicit permission for a fresh bootstrap plan covering the KMS key, alias, key policy, output, and deploy-role `kms:DescribeKey` grant. Apply only after that plan receives its own approval and allow time for IAM propagation.
2. After the bootstrap key and `alias/url-monitor-alerts` exist, create a fresh saved runtime plan. Runtime resolves the key by alias and does not read bootstrap state. Apply the runtime plan only through the existing production approval workflow.

The production schedule remains paused. Sampled X-Ray tracing is unrelated to SNS encryption and does not verify either publisher path.

## Publisher boundaries

The Lambda publisher retains `sns:Publish` through its project IAM policy. Its KMS use is separately limited to `kms:GenerateDataKey*` and `kms:Decrypt` on the exact alert key, through SNS in Seoul, with the exact alert-topic encryption context.

The CloudWatch publisher is granted `sns:Publish` by the topic policy only for the exact account and `url-monitor-lambda-errors` alarm. The key policy grants only the required cryptographic actions to the CloudWatch service with the same exact account, alarm, and topic encryption context. Combining those documented CloudWatch source restrictions with the SNS encryption context is a policy-design inference, not proof of live delivery.

SNS server-side encryption covers message bodies at rest in SNS. SNS subjects, message attributes, and email after delivery are outside that protection boundary. Each publisher path needs a separately approved, bounded delivery test; do not publish arbitrary alerts as part of deployment.

## Cost and lifecycle

The key initially costs USD 1 per month plus requests and tax. Each of the first two rotations adds USD 1 per month in key-storage charges. Keeping Scheduler OFF does not stop these charges.

Terraform `prevent_destroy` is configuration-only protection. Any key disablement or deletion requires a distinct review, including the operational and data-access consequences. Do not remove the guard or bypass KMS policy-lockout safety. The configured deletion waiting period is 30 days and annual rotation remains enabled.
