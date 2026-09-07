"""Exercise the security gate with real Checkov, not workflow text matches."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(
    importlib.util.find_spec("checkov") is None,
    reason="install requirements-security.txt in an isolated environment",
)


def run_gate(tmp_path, terraform):
    source = tmp_path / "source"
    source.mkdir()
    if terraform is not None:
        (source / "main.tf").write_text(terraform, encoding="utf-8")
    reports = tmp_path / "reports"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "security" / "scan.py"),
            "--directory", str(source),
            "--output-dir", str(reports),
        ],
        capture_output=True,
        text=True,
        timeout=180,
    )
    return result, reports


def test_public_bucket_fails_and_preserves_actual_findings(tmp_path):
    # Catches a soft-fail flag, swallowed scanner exit, or dropped report.
    result, reports = run_gate(tmp_path, '''
resource "aws_s3_bucket" "public" {
  bucket = "deliberately-insecure-ci-fixture"
  acl    = "public-read"
}
''')
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads((reports / "checkov.json").read_text(encoding="utf-8"))
    failures = report["results"]["failed_checks"]
    assert any(
        finding["check_id"] == "CKV_AWS_20"
        and finding["resource"] == "aws_s3_bucket.public"
        for finding in failures
    )
    assert "FAILED" in (reports / "summary.md").read_text(encoding="utf-8")


def test_empty_directory_is_not_a_clean_scan(tmp_path):
    # Catches reporting success when Checkov did not evaluate infrastructure.
    result, reports = run_gate(tmp_path, None)
    assert result.returncode == 2, result.stdout + result.stderr
    summary = (reports / "summary.md").read_text(encoding="utf-8")
    assert "ERROR" in summary
    assert "No resources evaluated" in summary


def test_malformed_terraform_is_not_a_clean_scan(tmp_path):
    # Catches Checkov parse errors being mistaken for zero findings.
    result, reports = run_gate(tmp_path, 'resource "aws_s3_bucket" "broken" {\n')
    assert result.returncode == 2, result.stdout + result.stderr
    summary = (reports / "summary.md").read_text(encoding="utf-8")
    assert "ERROR" in summary
    assert "Parsing errors" in summary


def test_clean_encrypted_topic_can_pass(tmp_path):
    # Catches a gate that always fails regardless of scanner evidence.
    result, reports = run_gate(tmp_path, '''
resource "aws_sns_topic" "encrypted" {
  name              = "secure-ci-fixture"
  kms_master_key_id = "alias/aws/sns"
}
''')
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((reports / "checkov.json").read_text(encoding="utf-8"))
    assert report["summary"]["failed"] == 0
    assert report["summary"]["passed"] > 0
    assert "PASSED" in (reports / "summary.md").read_text(encoding="utf-8")


def test_inline_suppression_is_not_implicitly_approved(tmp_path):
    # Catches a source comment silently bypassing the no-exception policy.
    result, reports = run_gate(tmp_path, '''
resource "aws_sns_topic" "unencrypted" {
  #checkov:skip=CKV_AWS_26:Deliberate test of an unapproved exception.
  name = "suppressed-ci-fixture"
}
''')
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads((reports / "checkov.json").read_text(encoding="utf-8"))
    assert report["summary"]["skipped"] == 1
    assert "FAILED" in (reports / "summary.md").read_text(encoding="utf-8")
