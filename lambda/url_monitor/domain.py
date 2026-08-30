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
