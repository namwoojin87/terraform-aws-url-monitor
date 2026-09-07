# Dashboard deployment permission verification

Verified on **2026-09-07 at 05:22:33 UTC** (14:22:33 Korea time). The user explicitly approved the exact dashboard permission addition. This record covers **IAM only**, not dashboard deployment, GitHub publication, or security exceptions.

## Approved and applied change

The existing `url-monitor-github-deploy` managed policy, attached only to the same-named deploy role, gained one statement named `ManageProjectDashboard`:

- `cloudwatch:GetDashboard`
- `cloudwatch:PutDashboard`
- `cloudwatch:DeleteDashboards`

The sole resource is `arn:aws:cloudwatch::<project-account>:dashboard/url-monitor-operations`. CloudWatch dashboard ARNs have no region component. This does not grant dashboard listing, custom metric publication, or access to other dashboard names.

The inspected Terraform saved plan contained **0 additions, 1 in-place change, and 0 destructions**. Its only managed-resource change was `aws_iam_policy.deploy`, and its only changed attribute was `policy`. All nine existing policy statements were semantically unchanged. The role trust policy, role identity, and policy attachments were unchanged. The policy was not attached to users, groups, other roles, or used as a permissions boundary.

The exact inspected saved plan was applied successfully. The policy had two versions before the operation and three afterward; no old policy version needed to be deleted. A subsequent AWS read confirmed that its default policy document matched the approved document.

## Permission checks

The actual deploy role was used as the IAM simulation source. Every returned resource-specific result was checked; missing context and truncated responses were rejected.

| Simulated scope | Action/resource cases | Before | After |
| --- | --- | --- | --- |
| Exact project dashboard | 3 approved actions | 3 denied | 3 allowed |
| Same account, `url-monitor-operations-other` | 3 approved actions | 3 denied | 3 denied |
| Same account, unrelated dashboard name | 3 approved actions | 3 denied | 3 denied |
| Synthetic other account, same dashboard name | 3 approved actions | 3 denied | 3 denied |
| `ListDashboards` and `PutMetricData` on `*` | 2 actions | 2 denied | 2 denied |

All **14 cases** matched expectations: three newly allowed cases and eleven denied negative cases after apply. The simulator requested existing unrelated `s3:prefix` and `iam:PassedToService` context; representative values from the existing policies were supplied (`infra/terraform.tfstate`, `lambda.amazonaws.com`). The added CloudWatch statement has no conditions involving either key.

IAM simulation evaluates policy behavior; it is **not proof that an actual dashboard API call or a GitHub OIDC deployment succeeded**. Resource-specific results and context handling are described in the [AWS simulation API reference](https://docs.aws.amazon.com/IAM/latest/APIReference/API_SimulatePrincipalPolicy.html).

## Final state and remaining work

- A fresh full bootstrap plan exited `0`: no remaining changes against the reviewed local configuration.
- Scheduler configuration, input, and `DISABLED` state were identical before and after the operation.
- The dashboard itself still did not exist. No runtime resource was created, and no Lambda invocation or notification was part of this IAM change.
- No Checkov exception was added. The last full local scan remains 152 passed checks, 20 failed checks, and 0 skipped checks.
- GitHub publication, security-finding review, protected runtime deployment, dashboard widget verification, and the submission PPT update remain pending.

The applied source was the current published base `cf52eea89e2e8d08e74d7f2cf47540a39f4aad15` plus the reviewed local `bootstrap/oidc.tf` patch. Its Git blob hash was verified as `e7c27cf22d5aaa2c17078ec66a7281fbfd342319` before planning and applying. This permission patch is not yet committed or merged into GitHub. **Do not apply the older bootstrap source from `main`: it does not yet contain this approved statement.** Publish and review the source change before the next bootstrap operation.

Raw plans, backend values, policy snapshots, account identifiers, and private inputs are deliberately excluded from this public record.
