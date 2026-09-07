import importlib.util
import json
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("drift_check", ROOT / "scripts/drift_check.py")
drift = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drift)

ADDRESS = "module.url_monitor.aws_scheduler_schedule.monitor"
SECRET = "DO_NOT_PUBLISH-private@example.invalid"


def stream(*events):
    return "\n".join(json.dumps(event) for event in (
        {"type": "version", "ui": "1.2", "terraform": "1.16.0"},
        *events,
        {"type": "change_summary", "changes": {"add": 0, "change": 0, "remove": 0, "operation": "plan"}},
    ))


def change(kind, action="update", address=ADDRESS):
    return {"type": kind, "change": {"resource": {"addr": address}, "action": action}}


def test_clean_plan_and_data_reads_are_not_managed_drift():
    status, report = drift.summarize_plan(0, stream(change("planned_change", "read", "data.archive_file.lambda")))
    assert status == "clean"
    assert "CLEAN" in report
    assert "data.archive_file" not in report


@pytest.mark.parametrize("action", ["create", "update", "delete", "replace", "move", "import"])
def test_planned_resource_changes_require_attention(action):
    status, report = drift.summarize_plan(2, stream(change("planned_change", action)))
    assert status == "drift"
    assert ADDRESS in report
    assert action in report
    assert "Proposed configuration changes" in report


def test_external_drift_is_detected_even_when_plan_exit_code_is_zero():
    status, report = drift.summarize_plan(0, stream(change("resource_drift")))
    assert status == "drift"
    assert "Observed external changes" in report
    assert ADDRESS in report


def test_output_only_diff_and_unclassified_exit_two_require_review_without_values():
    status, report = drift.summarize_plan(2, stream({"type": "outputs", "outputs": {
        "secret": {"action": "update", "sensitive": True, "value": SECRET}
    }}))
    assert status == "drift"
    assert SECRET not in report
    assert drift.summarize_plan(2, stream())[0] == "drift"


@pytest.mark.parametrize("output", ["", "not JSON", "[]", '{"type":"version","ui":"1.2"}',
    stream().replace('"1.2"', '"2.0"'), stream(change("resource_drift", "unknown"))])
def test_invalid_or_incomplete_output_never_reports_clean(output):
    status, report = drift.summarize_plan(0, output)
    assert status == "error"
    assert "ERROR" in report


@pytest.mark.parametrize("returncode", [0, 1, 2, 137])
def test_diagnostics_are_not_leaked_or_mistaken_for_drift(returncode):
    status, report = drift.summarize_plan(returncode, stream({
        "type": "diagnostic", "@level": "error", "@message": SECRET,
        "diagnostic": {"severity": "error", "summary": SECRET, "detail": SECRET},
    }))
    assert status == "error"
    assert SECRET not in report


def test_untrusted_messages_values_and_markdown_do_not_escape_into_report():
    event = change("planned_change", address="aws_example.item<unsafe>|`\n::error::bad")
    event["@message"] = SECRET
    event["change"]["before"] = {"password": SECRET}
    status, report = drift.summarize_plan(2, stream(event, {"type": "log", "@message": SECRET}))
    assert status == "drift"
    assert SECRET not in report
    assert "<unsafe>" not in report
    assert "\n::error::bad" not in report


def test_command_is_plan_only_with_locking_and_private_output(monkeypatch):
    calls = []
    waits = []

    class Process:
        returncode = 0

        def communicate(self, timeout):
            waits.append(timeout)
            return stream(), SECRET

    def run(command, **kwargs):
        calls.append((command, kwargs))
        return Process()

    monkeypatch.setattr(drift.subprocess, "Popen", run)
    monkeypatch.setenv("TF_LOG_PATH", "private.log")
    monkeypatch.setenv("TF_CLI_ARGS_plan", "-out=private.tfplan")
    status, report = drift.run_check("infra")
    command, options = calls[0]
    assert command == ["terraform", "-chdir=infra", "plan", "-input=false", "-json", "-detailed-exitcode", "-lock-timeout=60s"]
    assert options["stdout"] == subprocess.PIPE
    assert options["stderr"] == subprocess.PIPE
    assert waits == [600]
    assert "TF_LOG_PATH" not in options["env"]
    assert "TF_CLI_ARGS_plan" not in options["env"]
    assert status == "clean"
    assert SECRET not in report


@pytest.mark.parametrize("error", [FileNotFoundError(SECRET), PermissionError(SECRET)])
def test_process_failure_is_sanitized(monkeypatch, error):
    def run(*args, **kwargs):
        raise error

    monkeypatch.setattr(drift.subprocess, "Popen", run)
    status, report = drift.run_check("infra")
    assert status == "error"
    assert SECRET not in report


@pytest.mark.parametrize("needs_kill", [False, True])
def test_timeout_interrupts_terraform_before_forcing_shutdown(monkeypatch, needs_kill):
    actions = []

    class Process:
        returncode = 1

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def communicate(self, input=None, timeout=None):
            actions.append(("wait", timeout))
            if timeout == 600 or (timeout == 30 and needs_kill):
                raise subprocess.TimeoutExpired("terraform", timeout, output=SECRET)
            return "", ""

        def send_signal(self, signal):
            actions.append(("interrupt", signal))

        def kill(self):
            actions.append(("kill", None))

    monkeypatch.setattr(drift.subprocess, "Popen", lambda *args, **kwargs: Process())
    status, report = drift.run_check("infra")
    assert status == "error"
    expected = ["wait", "interrupt", "wait"] + (["kill", "wait"] if needs_kill else [])
    assert [action[0] for action in actions] == expected
    assert actions[2] == ("wait", 30)
    assert SECRET not in report


@pytest.mark.parametrize("status,expected", [("clean", 0), ("drift", 2), ("error", 1)])
def test_cli_publishes_only_safe_summary_and_fails_on_nonclean(monkeypatch, tmp_path, capsys, status, expected):
    report = "# Terraform drift check\n\n" + status.upper() + "\n"
    monkeypatch.setattr(drift, "run_check", lambda *args: (status, report))
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    assert drift.main([]) == expected
    assert summary.read_text(encoding="utf-8") == report
    assert status.upper() in capsys.readouterr().out
