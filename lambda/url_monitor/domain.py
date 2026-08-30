from dataclasses import dataclass


@dataclass(frozen=True)
class Target:
    name: str
    url: str
    expected_statuses: frozenset[int]
    timeout_seconds: int


@dataclass(frozen=True)
class CheckResult:
    healthy: bool
    status_code: int | None
    response_ms: int | None
    error_category: str | None
    error_message: str | None


@dataclass(frozen=True)
class StoredState:
    status: str
    consecutive_failures: int
    checked_at: str
    last_changed_at: str
    response_ms: int | None
    last_error: str | None
    expires_at: int


@dataclass(frozen=True)
class StateDecision:
    state: StoredState
    notification: str | None


def decide_state(
    current: StoredState | None,
    result: CheckResult,
    threshold: int,
    checked_at: str,
    expires_at: int,
) -> StateDecision:
    previous_status = current.status if current else None
    failures = 0 if result.healthy else (current.consecutive_failures if current else 0) + 1
    if result.healthy:
        status = "UP"
    elif failures >= threshold:
        status = "DOWN"
    else:
        status = "PENDING_DOWN"

    notification = None
    if status == "DOWN" and previous_status != "DOWN":
        notification = "OUTAGE"
    elif status == "UP" and previous_status == "DOWN":
        notification = "RECOVERY"

    last_changed_at = (
        checked_at
        if current is None or previous_status != status
        else current.last_changed_at
    )
    error = None if result.healthy else f"{result.error_category}: {result.error_message}"
    return StateDecision(
        StoredState(status, failures, checked_at, last_changed_at, result.response_ms, error, expires_at),
        notification,
    )
