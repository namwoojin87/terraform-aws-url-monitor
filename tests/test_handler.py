from datetime import datetime, timedelta, timezone

import pytest

from url_monitor.domain import CheckResult, StoredState
from url_monitor.handler import run

NOW = datetime(2026, 8, 30, 1, 0, tzinfo=timezone.utc)
EVENT = {
    "failure_threshold": 2,
    "state_ttl_days": 7,
    "history_ttl_days": 7,
    "targets": {
        "demo": {
            "url": "https://example.com",
            "expected_statuses": [200],
            "timeout_seconds": 5,
        }
    },
}


class MemoryRepository:
    def __init__(self, states=None, operations=None):
        self.states = states or {}
        self.operations = operations

    def get(self, monitor_id):
        return self.states.get(monitor_id)

    def put(self, monitor_id, state):
        if self.operations is not None:
            self.operations.append(("state", monitor_id))
        self.states[monitor_id] = state


class MemoryHistoryRepository:
    def __init__(self, failing_monitor=None, operations=None):
        self.items = []
        self.failing_monitor = failing_monitor
        self.operations = operations

    def put(self, monitor_id, checked_at, result, state, expires_at):
        if monitor_id == self.failing_monitor:
            raise RuntimeError("history unavailable")
        if self.operations is not None:
            self.operations.append(("history", monitor_id))
        self.items.append((monitor_id, checked_at, result, state, expires_at))


class MemoryNotifier:
    def __init__(self):
        self.events = []

    def publish(self, kind, target, result, checked_at):
        self.events.append((kind, target.name, result.error_category, checked_at))


def test_run_publishes_outage_before_committing_down_state():
    repository = MemoryRepository(
        {"demo": StoredState("PENDING_DOWN", 1, NOW.isoformat(), NOW.isoformat(), None, "DNS", 0)}
    )
    notifier = MemoryNotifier()
    result = CheckResult(False, None, 5000, "DNS", "name not known")

    output = run(EVENT, repository, MemoryHistoryRepository(), notifier, lambda _target: result, NOW)

    assert output == {"checked": 1, "errors": 0}
    assert notifier.events[0][0] == "OUTAGE"
    assert repository.states["demo"].status == "DOWN"


def test_run_recovers_without_repeating_outage():
    repository = MemoryRepository(
        {"demo": StoredState("DOWN", 3, NOW.isoformat(), NOW.isoformat(), None, "DNS", 0)}
    )
    notifier = MemoryNotifier()
    result = CheckResult(True, 200, 30, None, None)

    run(EVENT, repository, MemoryHistoryRepository(), notifier, lambda _target: result, NOW)

    assert [event[0] for event in notifier.events] == ["RECOVERY"]
    assert repository.states["demo"].status == "UP"


def test_one_internal_error_does_not_skip_remaining_target():
    event = {
        **EVENT,
        "targets": {
            "broken": EVENT["targets"]["demo"],
            "healthy": EVENT["targets"]["demo"],
        },
    }
    repository = MemoryRepository()
    history = MemoryHistoryRepository()
    notifier = MemoryNotifier()

    def checker(target):
        if target.name == "broken":
            raise ValueError("bad fixture")
        return CheckResult(True, 200, 20, None, None)

    with pytest.raises(RuntimeError, match="broken"):
        run(event, repository, history, notifier, checker, NOW)

    assert repository.states["healthy"].status == "UP"
    assert [item[0] for item in history.items] == ["healthy"]


def test_malformed_target_does_not_skip_remaining_target():
    event = {
        **EVENT,
        "targets": {
            "malformed": {"expected_statuses": [200], "timeout_seconds": 5},
            "healthy": EVENT["targets"]["demo"],
        },
    }
    repository = MemoryRepository()
    history = MemoryHistoryRepository()
    notifier = MemoryNotifier()

    with pytest.raises(RuntimeError, match="malformed"):
        run(event, repository, history, notifier, lambda _target: CheckResult(True, 200, 20, None, None), NOW)

    assert repository.states["healthy"].status == "UP"
    assert [item[0] for item in history.items] == ["healthy"]


def test_notification_failure_does_not_commit_transition():
    repository = MemoryRepository(
        {"demo": StoredState("PENDING_DOWN", 1, NOW.isoformat(), NOW.isoformat(), None, "DNS", 0)}
    )

    class FailingNotifier:
        def publish(self, *_args):
            raise RuntimeError("SNS unavailable")

    result = CheckResult(False, None, 5000, "DNS", "name not known")
    with pytest.raises(RuntimeError, match="demo"):
        run(EVENT, repository, MemoryHistoryRepository(), FailingNotifier(), lambda _target: result, NOW)

    assert repository.states["demo"].status == "PENDING_DOWN"


def test_run_writes_state_before_one_history_item():
    operations = []
    repository = MemoryRepository(operations=operations)
    history = MemoryHistoryRepository(operations=operations)
    result = CheckResult(True, 200, 20, None, None)

    output = run(EVENT, repository, history, MemoryNotifier(), lambda _target: result, NOW)

    assert output == {"checked": 1, "errors": 0}
    assert operations == [("state", "demo"), ("history", "demo")]
    monitor_id, checked_at, recorded, state, expires_at = history.items[0]
    assert monitor_id == "demo"
    assert checked_at == NOW.isoformat()
    assert recorded == result
    assert state.status == "UP"
    assert expires_at == int((NOW + timedelta(days=7)).timestamp())


def test_history_failure_does_not_skip_later_target():
    event = {
        **EVENT,
        "targets": {
            "history-broken": EVENT["targets"]["demo"],
            "healthy": EVENT["targets"]["demo"],
        },
    }
    repository = MemoryRepository()
    history = MemoryHistoryRepository(failing_monitor="history-broken")

    with pytest.raises(RuntimeError, match="history-broken"):
        run(
            event,
            repository,
            history,
            MemoryNotifier(),
            lambda _target: CheckResult(True, 200, 20, None, None),
            NOW,
        )

    assert repository.states["history-broken"].status == "UP"
    assert repository.states["healthy"].status == "UP"
    assert [item[0] for item in history.items] == ["healthy"]
