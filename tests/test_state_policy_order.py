import re
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def test_state_bucket_policy_uses_known_role_arns_and_waits_for_role_creation():
    source = (REPOSITORY_ROOT / "bootstrap" / "oidc.tf").read_text(encoding="utf-8")
    boundary = re.search(
        r'data "aws_iam_policy_document" "github_state_boundary" \{(?P<body>.*?)\n\}\n\nresource "aws_s3_bucket_policy"',
        source,
        re.DOTALL,
    )
    bucket_policy = re.search(
        r'resource "aws_s3_bucket_policy" "state" \{(?P<body>.*?)\n\}',
        source,
        re.DOTALL,
    )

    assert '"arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-github-plan"' in source
    assert '"arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-github-deploy"' in source
    assert boundary is not None
    assert "identifiers = local.github_role_arns" in boundary.group("body")
    assert "aws_iam_role.plan.arn" not in boundary.group("body")
    assert "aws_iam_role.deploy.arn" not in boundary.group("body")
    assert bucket_policy is not None
    assert re.search(
        r"depends_on\s*=\s*\[\s*aws_iam_role\.plan,\s*aws_iam_role\.deploy,?\s*\]",
        bucket_policy.group("body"),
        re.DOTALL,
    )
