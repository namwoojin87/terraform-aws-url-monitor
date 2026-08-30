from datetime import datetime, timezone

import pytest

from url_monitor.domain import CheckResult, StoredState
from url_monitor.handler import run

NOW = datetime(2026, 8, 30, 1, 0, tzinfo=timezone.utc)
EVENT = {
    "failure_threshold": 2,
    "state_ttl_days": 7,
    "targets": {
        "demo": {
            "url": "https://example.com",
            "expected_statuses": [200],
            "timeout_seconds": 5,
        }
    },
}


class MemoryRepository:
    def __init__(self, states=None):
        self.states = states or {}

    def get(self, monitor_id):
        return self.states.get(monitor_id)

    def put(self, monitor_id, state):
        self.states[monitor_id] = state


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

    output = run(EVENT, repository, notifier, lambda _target: result, NOW)

    assert output == {"checked": 1, "errors": 0}
    assert notifier.events[0][0] == "OUTAGE"
    assert repository.states["demo"].status == "DOWN"


def test_run_recovers_without_repeating_outage():
    repository = MemoryRepository(
        {"demo": StoredState("DOWN", 3, NOW.isoformat(), NOW.isoformat(), None, "DNS", 0)}
    )
    notifier = MemoryNotifier()
    result = CheckResult(True, 200, 30, None, None)

    run(EVENT, repository, notifier, lambda _target: result, NOW)

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
    notifier = MemoryNotifier()

    def checker(target):
        if target.name == "broken":
            raise ValueError("bad fixture")
        return CheckResult(True, 200, 20, None, None)

    with pytest.raises(RuntimeError, match="broken"):
        run(event, repository, notifier, checker, NOW)

    assert repository.states["healthy"].status == "UP"


def test_notification_failure_does_not_commit_transition():
    repository = MemoryRepository(
        {"demo": StoredState("PENDING_DOWN", 1, NOW.isoformat(), NOW.isoformat(), None, "DNS", 0)}
    )

    class FailingNotifier:
        def publish(self, *_args):
            raise RuntimeError("SNS unavailable")

    result = CheckResult(False, None, 5000, "DNS", "name not known")
    with pytest.raises(RuntimeError, match="demo"):
        run(EVENT, repository, FailingNotifier(), lambda _target: result, NOW)

    assert repository.states["demo"].status == "PENDING_DOWN"
