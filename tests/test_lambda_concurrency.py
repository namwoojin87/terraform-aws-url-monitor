from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def test_monitor_uses_unreserved_lambda_concurrency_with_bounded_runtime_schedule():
    module = (REPOSITORY_ROOT / "modules" / "url-monitor" / "main.tf").read_text(encoding="utf-8")
    live_root = (REPOSITORY_ROOT / "infra" / "main.tf").read_text(encoding="utf-8")

    assert "timeout          = 30" in module
    assert "reserved_concurrent_executions" not in module
    assert 'schedule_expression = "rate(5 minutes)"' in live_root
