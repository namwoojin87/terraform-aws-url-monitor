# Task 2 Report: Pure Outage and Recovery State Machine

## Implementation

Added immutable `StoredState` and `StateDecision` dataclasses and the pure `decide_state` transition function to `lambda/url_monitor/domain.py`.

The state machine now initializes successful checks as `UP`, tracks failures as `PENDING_DOWN`, transitions at the configured threshold to `DOWN` with a single `OUTAGE` notification, suppresses duplicate outage notifications, and emits one `RECOVERY` notification when a down target returns to `UP`. It preserves `last_changed_at` while the status is unchanged and updates response/error/expiry metadata on every decision.

## Files changed

- `lambda/url_monitor/domain.py`
- `tests/test_domain.py`

## TDD evidence

### RED

Added the initial state and threshold tests, then ran:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_domain.py -q
```

Result: failed during test collection with `ImportError: cannot import name 'StoredState' from 'url_monitor.domain'`, because the requested production API did not yet exist.

### GREEN

Implemented the specified state types and transition logic, added the no-duplicate and recovery tests, then ran:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_domain.py -q
```

Output:

```text
......                                                                   [100%]
```

## Verification

Ran the full suite:

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

Output:

```text
............                                                             [100%]
```

Also ran `git diff --check`; it reported no whitespace errors. Git emitted only its normal LF/CRLF conversion warning for `domain.py`.

## Self-review

- Preserved the existing `Target` and `CheckResult` definitions and behavior.
- Kept all new dataclasses frozen to preserve immutable state values.
- Kept `decide_state` pure: it reads its inputs and returns a new decision/state without persistence, notification side effects, or AWS dependencies.
- Confirmed threshold transition, repeated outage suppression, recovery notification, pending-failure clearing, error formatting, and timestamp behavior through focused tests.

## Concerns

The brief specifies the exact transition logic and leaves validation of threshold values and Terraform defaults to later work. Accordingly, this implementation does not add validation for invalid thresholds or status strings.
