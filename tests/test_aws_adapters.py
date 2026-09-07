from unittest.mock import MagicMock

from url_monitor.aws_adapters import DynamoHistoryRepository, DynamoStateRepository, SnsNotifier
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


def test_history_repository_writes_queryable_failure_without_null_fields():
    table = MagicMock()
    repository = DynamoHistoryRepository(table)
    result = CheckResult(False, None, 5000, "DNS", "name not known")
    state = StoredState(
        "DOWN",
        2,
        "2026-09-03T01:00:00+00:00",
        "2026-09-03T01:00:00+00:00",
        5000,
        "DNS: name not known",
        1788406800,
    )

    repository.put(
        "demo",
        "2026-09-03T01:00:00+00:00",
        result,
        state,
        1789000000,
    )

    assert table.put_item.call_args.kwargs["Item"] == {
        "monitor_id": "demo",
        "checked_at": "2026-09-03T01:00:00+00:00",
        "healthy": False,
        "state": "DOWN",
        "response_ms": 5000,
        "error_category": "DNS",
        "expires_at": 1789000000,
    }


def test_history_repository_writes_http_status_and_omits_absent_error():
    table = MagicMock()
    repository = DynamoHistoryRepository(table)
    result = CheckResult(True, 200, 21, None, None)
    state = StoredState(
        "UP",
        0,
        "2026-09-03T01:00:00+00:00",
        "2026-09-03T01:00:00+00:00",
        21,
        None,
        1788406800,
    )

    repository.put(
        "demo",
        "2026-09-03T01:00:00+00:00",
        result,
        state,
        1789000000,
    )

    written = table.put_item.call_args.kwargs["Item"]
    assert written["status_code"] == 200
    assert "error_category" not in written
    assert "error_message" not in written
    assert "url" not in written


def test_notifier_publishes_structured_transition():
    client = MagicMock()
    notifier = SnsNotifier(client, "arn:aws:sns:ap-northeast-2:123456789012:url-monitor-alerts")
    target = Target("demo", "https://example.com", frozenset({200}), 5)
    result = CheckResult(False, None, 5000, "DNS", "name not known")

    notifier.publish("OUTAGE", target, result, "2026-08-30T01:00:00+00:00")

    request = client.publish.call_args.kwargs
    assert request["Subject"] == "[url-monitor] OUTAGE: demo"
    assert '"error_category": "DNS"' in request["Message"]
