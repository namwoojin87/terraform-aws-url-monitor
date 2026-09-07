"""Exercise malformed scanner evidence without requiring Checkov installation."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("security_scan", ROOT / "security/scan.py")
scan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scan)


@pytest.mark.parametrize("scanner_exit", [0, 1], ids=["claimed-pass", "claimed-fail"])
@pytest.mark.parametrize(
    "finding", [{}, [], {"file_path": None}],
    ids=["missing-field", "wrong-type", "null-path"],
)
def test_invalid_finding_overrides_scanner_decision(tmp_path, monkeypatch, scanner_exit, finding):
    # Catches returning a previously selected success/finding code after evidence parsing fails.
    report = {
        "summary": {
            "passed": 1, "failed": scanner_exit, "skipped": 0,
            "parsing_errors": 0, "resource_count": 1,
        },
        "results": {"failed_checks": [finding], "skipped_checks": []},
    }

    def emit_scanner_report(command, *, stdout, stderr, env, timeout):
        # Replace only the external scanner; exercise the real parsing, summary and exit handling.
        json.dump(report, stdout)
        return subprocess.CompletedProcess(command, scanner_exit)

    reports = tmp_path / "reports"
    monkeypatch.setattr(scan.subprocess, "run", emit_scanner_report)
    monkeypatch.setattr(sys, "argv", ["scan.py", "--output-dir", str(reports)])

    assert scan.main() == 2
    summary = (reports / "summary.md").read_text(encoding="utf-8")
    assert "ERROR:" in summary
    assert "PASSED:" not in summary
    assert json.loads((reports / "checkov.json").read_text(encoding="utf-8")) == report
