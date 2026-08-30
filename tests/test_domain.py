from url_monitor.domain import CheckResult, StoredState, decide_state


NOW = "2026-08-30T01:00:00+00:00"
EXPIRES = 1788666000
UP = CheckResult(True, 200, 42, None, None)
DOWN = CheckResult(False, None, 5000, "DNS", "name not known")


def test_first_success_initializes_up_without_notification():
    decision = decide_state(None, UP, 2, NOW, EXPIRES)
    assert decision.state.status == "UP"
    assert decision.state.consecutive_failures == 0
    assert decision.notification is None


def test_first_failure_is_pending_without_notification():
    decision = decide_state(None, DOWN, 2, NOW, EXPIRES)
    assert decision.state.status == "PENDING_DOWN"
    assert decision.state.consecutive_failures == 1
    assert decision.notification is None


def test_second_failure_transitions_to_down():
    current = StoredState("PENDING_DOWN", 1, NOW, NOW, None, "DNS: name not known", EXPIRES)
    decision = decide_state(current, DOWN, 2, NOW, EXPIRES)
    assert decision.state.status == "DOWN"
    assert decision.notification == "OUTAGE"


def test_continued_outage_does_not_repeat_notification():
    current = StoredState("DOWN", 2, NOW, NOW, None, "DNS: name not known", EXPIRES)
    decision = decide_state(current, DOWN, 2, NOW, EXPIRES)
    assert decision.state.status == "DOWN"
    assert decision.state.consecutive_failures == 3
    assert decision.notification is None


def test_recovery_sends_one_recovery_notification():
    current = StoredState("DOWN", 3, NOW, NOW, None, "DNS: name not known", EXPIRES)
    decision = decide_state(current, UP, 2, NOW, EXPIRES)
    assert decision.state.status == "UP"
    assert decision.state.consecutive_failures == 0
    assert decision.state.last_error is None
    assert decision.notification == "RECOVERY"


def test_success_after_one_failure_clears_pending_state_without_notification():
    current = StoredState("PENDING_DOWN", 1, NOW, NOW, None, "TIMEOUT: timed out", EXPIRES)
    decision = decide_state(current, UP, 2, NOW, EXPIRES)
    assert decision.state.status == "UP"
    assert decision.state.consecutive_failures == 0
    assert decision.notification is None
