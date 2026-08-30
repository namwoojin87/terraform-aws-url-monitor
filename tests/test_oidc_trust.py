from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def test_bootstrap_trust_binds_the_immutable_github_owner_and_repository_ids():
    variables = (REPOSITORY_ROOT / "bootstrap" / "variables.tf").read_text(encoding="utf-8")
    trust = (REPOSITORY_ROOT / "bootstrap" / "oidc.tf").read_text(encoding="utf-8")

    assert 'variable "github_owner_id"' in variables
    assert 'variable "github_repository_id"' in variables
    assert (
        "repo:${var.github_owner}@${var.github_owner_id}/"
        "${var.github_repository}@${var.github_repository_id}:ref:refs/heads/main"
    ) in trust
    assert (
        "repo:${var.github_owner}@${var.github_owner_id}/"
        "${var.github_repository}@${var.github_repository_id}:environment:production"
    ) in trust
