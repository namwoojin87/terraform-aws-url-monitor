from unittest.mock import MagicMock

from url_monitor.aws_adapters import DynamoStateRepository, SnsNotifier
from url_monitor.domain import CheckResult, StoredState, Target


def test_repository_reads_and_writes_explicit_state_fields():
    table = MagicMock()
    table.get_item.return_value = {
        "Item": {
            "monitor_id": "demo",
            "status": "UP",
            "consecutive_failures": 0,
            "checked_at": "2026-08-30T01:00:00+00:00",
            "last_changed_at": "2026-08-30T01:00:00+00:00",
            "response_ms": 21,
            "expires_at": 1788666000,
        }
    }
    repository = DynamoStateRepository(table)

    state = repository.get("demo")
    repository.put("demo", state)

    assert state.status == "UP"
    assert state.last_error is None
    written = table.put_item.call_args.kwargs["Item"]
    assert written["monitor_id"] == "demo"
    assert "last_error" not in written


def test_notifier_publishes_structured_transition():
    client = MagicMock()
    notifier = SnsNotifier(client, "arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts")
    target = Target("demo", "https://example.com", frozenset({200}), 5)
    result = CheckResult(False, None, 5000, "DNS", "name not known")

    notifier.publish("OUTAGE", target, result, "2026-08-30T01:00:00+00:00")

    request = client.publish.call_args.kwargs
    assert request["Subject"] == "[url-monitor] OUTAGE: demo"
    assert '"error_category": "DNS"' in request["Message"]
