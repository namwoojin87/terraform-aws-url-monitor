# Terraform AWS URL Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and operate a low-cost AWS URL monitor that detects two consecutive failures, sends outage and recovery email, and is deployed through an approved Terraform GitHub Actions workflow.

**Architecture:** EventBridge Scheduler invokes a Python Lambda every five minutes. The Lambda checks up to five public endpoints, stores current state in DynamoDB, sends state-transition alerts through SNS, and exposes execution failures through CloudWatch; Terraform state lives in a versioned S3 backend with native lock files.

**Tech Stack:** Terraform 1.16.0, HashiCorp AWS provider 6.x, Archive provider 2.8.x, AWS Lambda Python 3.13, pytest, TFLint, GitHub Actions, AWS OIDC federation.

**Spec:** `docs/superpowers/specs/2026-08-30-terraform-aws-url-monitor-design.md`

## Global Constraints

- Deploy only to AWS region `ap-northeast-2`.
- Run checks every five minutes and support one to five HTTP(S) targets.
- Accept per-target timeouts from one through five seconds; use five seconds by default.
- Require two consecutive failures before an outage transition.
- Keep CloudWatch logs for seven days.
- Use Lambda, EventBridge Scheduler, DynamoDB on-demand capacity, SNS email, CloudWatch, S3, IAM, and AWS Budgets only.
- Do not add a VPC, NAT Gateway, EC2 instance, load balancer, database server, public IPv4 address, custom domain, dashboard, or historical event store.
- Keep Lambda outside a VPC and use only Python standard-library HTTP code plus the runtime-provided AWS SDK.
- Store Terraform state in a versioned, encrypted, public-blocked S3 bucket with `use_lockfile = true`.
- Never use root access keys or store long-lived AWS keys in GitHub.
- Restrict GitHub OIDC plan access to the repository's `main` branch and deploy access to its `production` environment.
- Keep `alert_email`, local variable files, state, plan files, zip packages, caches, and credentials out of Git.
- Use test-first implementation for Python behavior and Terraform module constraints.
- Use PowerShell for local Windows commands and Ubuntu shell commands only inside GitHub Actions.

## File Map

- `.gitignore` — excludes local credentials, Terraform state and plans, Python caches, and Lambda archives.
- `.terraform-version` — pins Terraform CLI 1.16.0 for local and CI consistency.
- `requirements-dev.txt` — local Python test dependencies only.
- `pyproject.toml` — pytest import path and test discovery.
- `.tflint.hcl` — repository-wide Terraform lint rules.
- `lambda/url_monitor/domain.py` — immutable domain types and pure state transition logic.
- `lambda/url_monitor/checker.py` — HTTP request execution and network-error classification.
- `lambda/url_monitor/aws_adapters.py` — DynamoDB state repository and SNS notification adapter.
- `lambda/url_monitor/handler.py` — Lambda event parsing and orchestration.
- `tests/test_checker.py` — HTTP outcome tests.
- `tests/test_domain.py` — state-machine tests.
- `tests/test_aws_adapters.py` — DynamoDB serialization and SNS request tests.
- `tests/test_handler.py` — orchestration, ordering, and isolation tests.
- `modules/url-monitor/versions.tf` — module Terraform and provider constraints.
- `modules/url-monitor/variables.tf` — module inputs and validation.
- `modules/url-monitor/iam.tf` — Lambda and Scheduler runtime roles and policies.
- `modules/url-monitor/main.tf` — SNS, DynamoDB, Lambda, Scheduler, logs, and alarm.
- `modules/url-monitor/outputs.tf` — observable resource identifiers.
- `modules/url-monitor/tests/module.tftest.hcl` — mocked-provider module plans and assertions.
- `bootstrap/backend.tf` — partial S3 backend block for post-bootstrap state migration.
- `bootstrap/versions.tf` — bootstrap provider constraints.
- `bootstrap/variables.tf` — GitHub owner/repository names and immutable IDs, email, region, and naming inputs.
- `bootstrap/main.tf` — state bucket, encryption, versioning, public access block, and budget.
- `bootstrap/oidc.tf` — GitHub OIDC provider, plan role, deploy role, and their policies.
- `bootstrap/outputs.tf` — state bucket, AWS account, and GitHub role ARNs.
- `bootstrap/tests/bootstrap.tftest.hcl` — mocked bootstrap safety assertions.
- `infra/backend.tf` — partial S3 backend block for live infrastructure.
- `infra/versions.tf` — live-root Terraform and provider constraints.
- `infra/variables.tf` — live-root sensitive and operational inputs.
- `infra/package.tf` — reproducible Lambda archive.
- `infra/main.tf` — provider configuration and URL-monitor module call.
- `infra/monitor.auto.tfvars.json` — committed, non-secret target definitions used by the portfolio demonstration.
- `infra/outputs.tf` — topic, table, function, schedule, and log group names.
- `.github/workflows/ci.yml` — credential-free pull-request validation.
- `.github/workflows/deploy.yml` — OIDC plan, one-day plan artifact, environment approval, exact-plan apply or destroy.
- `README.md` — portfolio overview, architecture, setup, demonstration, and cost controls.
- `docs/runbook.md` — operating, troubleshooting, target-change, and teardown procedures.

---

### Task 1: Repository Guardrails and HTTP Checker

**Files:**
- Create: `.gitignore`
- Create: `.terraform-version`
- Create: `requirements-dev.txt`
- Create: `pyproject.toml`
- Create: `lambda/url_monitor/__init__.py`
- Create: `lambda/url_monitor/domain.py`
- Create: `lambda/url_monitor/checker.py`
- Create: `tests/test_checker.py`

**Interfaces:**
- Produces: `Target(name: str, url: str, expected_statuses: frozenset[int], timeout_seconds: int)`.
- Produces: `CheckResult(healthy: bool, status_code: int | None, response_ms: int | None, error_category: str | None, error_message: str | None)`.
- Produces: `check_url(target: Target, opener: Callable = urllib.request.urlopen) -> CheckResult`.

- [ ] **Step 1: Verify the local toolchain without changing AWS**

Run:

```powershell
git status --short
terraform version
aws --version
py -3.13 --version
gh --version
```

Expected: Git reports only known work; Terraform is 1.16.0, AWS CLI and GitHub CLI respond, and Python 3.13 is available. Install only a missing tool before continuing:

```powershell
winget install -e --id Hashicorp.Terraform
winget install -e --id Amazon.AWSCLI
winget install -e --id Python.Python.3.13
winget install -e --id GitHub.cli
```

- [ ] **Step 2: Add repository exclusions and Python test configuration**

Create `.gitignore`:

```gitignore
.venv/
__pycache__/
.pytest_cache/
*.py[cod]

.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.zip
terraform.tfvars
backend.hcl
crash.log

.idea/
.vscode/settings.json
```

Create `.terraform-version`:

```text
1.16.0
```

Create `requirements-dev.txt`:

```text
boto3>=1.40,<2
pytest>=8,<10
```

Create `pyproject.toml`:

```toml
[tool.pytest.ini_options]
pythonpath = ["lambda"]
testpaths = ["tests"]
addopts = "-q"
```

Create an empty `lambda/url_monitor/__init__.py`.

- [ ] **Step 3: Write the failing happy-path checker test**

Create `tests/test_checker.py`:

```python
from url_monitor.checker import check_url
from url_monitor.domain import Target


class FakeResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


def test_check_url_returns_healthy_for_expected_status():
    target = Target("example", "https://example.com", frozenset({200}), 5)
    result = check_url(target, opener=lambda *_args, **_kwargs: FakeResponse())

    assert result.healthy is True
    assert result.status_code == 200
    assert result.error_category is None
    assert result.response_ms is not None
```

- [ ] **Step 4: Run the focused test and confirm the expected failure**

Run:

```powershell
py -3.13 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m pytest tests/test_checker.py -q
```

Expected: FAIL because `url_monitor.checker` and `Target` do not exist.

- [ ] **Step 5: Add the minimum domain types and happy-path checker**

Create `lambda/url_monitor/domain.py`:

```python
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
```

Create `lambda/url_monitor/checker.py`:

```python
from time import perf_counter
from urllib.request import Request, urlopen

from url_monitor.domain import CheckResult, Target


def check_url(target: Target, opener=urlopen) -> CheckResult:
    started = perf_counter()
    request = Request(target.url, headers={"User-Agent": "terraform-url-monitor/1.0"})
    with opener(request, timeout=target.timeout_seconds) as response:
        elapsed_ms = round((perf_counter() - started) * 1000)
        status = response.status
        return CheckResult(
            healthy=status in target.expected_statuses,
            status_code=status,
            response_ms=elapsed_ms,
            error_category=None if status in target.expected_statuses else "HTTP_STATUS",
            error_message=None if status in target.expected_statuses else f"unexpected status {status}",
        )
```

- [ ] **Step 6: Run the happy-path test**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_checker.py -q
```

Expected: PASS.

- [ ] **Step 7: Add failing network and HTTP classification tests**

Append to `tests/test_checker.py`:

```python
import socket
import ssl
from urllib.error import HTTPError, URLError

import pytest


@pytest.mark.parametrize(
    ("error", "category"),
    [
        (HTTPError("https://example.com", 503, "down", {}, None), "HTTP_STATUS"),
        (URLError(socket.gaierror("name not known")), "DNS"),
        (URLError(ssl.SSLError("certificate verify failed")), "TLS"),
        (TimeoutError("timed out"), "TIMEOUT"),
        (URLError(ConnectionRefusedError("refused")), "CONNECTION"),
    ],
)
def test_check_url_classifies_failures(error, category):
    target = Target("example", "https://example.com", frozenset({200}), 5)

    def fail(*_args, **_kwargs):
        raise error

    result = check_url(target, opener=fail)
    assert result.healthy is False
    assert result.error_category == category
```

- [ ] **Step 8: Run the tests and confirm classification failures**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_checker.py -q
```

Expected: five parameterized cases FAIL because exceptions escape `check_url`.

- [ ] **Step 9: Add concrete failure classification**

Extend `lambda/url_monitor/checker.py` with imports and exception handling:

```python
import socket
import ssl
from urllib.error import HTTPError, URLError


def _failure(category: str, message: str, started: float, status: int | None = None) -> CheckResult:
    return CheckResult(False, status, round((perf_counter() - started) * 1000), category, message)
```

Wrap the request block in `check_url` with these ordered handlers:

```python
    try:
        with opener(request, timeout=target.timeout_seconds) as response:
            elapsed_ms = round((perf_counter() - started) * 1000)
            status = response.status
            return CheckResult(
                healthy=status in target.expected_statuses,
                status_code=status,
                response_ms=elapsed_ms,
                error_category=None if status in target.expected_statuses else "HTTP_STATUS",
                error_message=None if status in target.expected_statuses else f"unexpected status {status}",
            )
    except HTTPError as error:
        return _failure("HTTP_STATUS", str(error), started, error.code)
    except TimeoutError as error:
        return _failure("TIMEOUT", str(error), started)
    except URLError as error:
        reason = error.reason
        if isinstance(reason, socket.gaierror):
            category = "DNS"
        elif isinstance(reason, ssl.SSLError):
            category = "TLS"
        elif isinstance(reason, (TimeoutError, socket.timeout)):
            category = "TIMEOUT"
        else:
            category = "CONNECTION"
        return _failure(category, str(reason), started)
```

- [ ] **Step 10: Run all checker tests**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_checker.py -q
```

Expected: PASS.

- [ ] **Step 11: Commit the independently testable checker**

Run:

```powershell
git add .gitignore .terraform-version requirements-dev.txt pyproject.toml lambda tests/test_checker.py
git commit -m "feat: add URL health checker"
```

Expected: one commit with passing checker tests and no AWS changes.

---

### Task 2: Pure Outage and Recovery State Machine

**Files:**
- Modify: `lambda/url_monitor/domain.py`
- Create: `tests/test_domain.py`

**Interfaces:**
- Consumes: `CheckResult` from Task 1.
- Produces: `StoredState(status: str, consecutive_failures: int, checked_at: str, last_changed_at: str, response_ms: int | None, last_error: str | None, expires_at: int)`.
- Produces: `StateDecision(state: StoredState, notification: str | None)`.
- Produces: `decide_state(current: StoredState | None, result: CheckResult, threshold: int, checked_at: str, expires_at: int) -> StateDecision`.

- [ ] **Step 1: Write failing initial-state and threshold tests**

Create `tests/test_domain.py`:

```python
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
```

- [ ] **Step 2: Run the state tests and confirm failure**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_domain.py -q
```

Expected: FAIL because `StoredState` and `decide_state` do not exist.

- [ ] **Step 3: Add state types and minimum threshold logic**

Append to `lambda/url_monitor/domain.py`:

```python
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
```

- [ ] **Step 4: Run the initial state-machine tests**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_domain.py -q
```

Expected: PASS.

- [ ] **Step 5: Add failing no-duplicate and recovery tests**

Append to `tests/test_domain.py`:

```python
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
```

- [ ] **Step 6: Run all state-machine tests**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_domain.py -q
```

Expected: PASS, proving normal repeated failures do not repeat an outage email.

- [ ] **Step 7: Run the full Python suite and commit**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest -q
git add lambda/url_monitor/domain.py tests/test_domain.py
git commit -m "feat: add outage transition state machine"
```

Expected: all Python tests PASS and the state machine is committed separately from AWS integration.

---

### Task 3: DynamoDB, SNS, and Lambda Orchestration

**Files:**
- Create: `lambda/url_monitor/aws_adapters.py`
- Create: `lambda/url_monitor/handler.py`
- Create: `tests/test_aws_adapters.py`
- Create: `tests/test_handler.py`

**Interfaces:**
- Consumes: `Target`, `StoredState`, `StateDecision`, `check_url`, and `decide_state`.
- Produces: `DynamoStateRepository.get(monitor_id: str) -> StoredState | None`.
- Produces: `DynamoStateRepository.put(monitor_id: str, state: StoredState) -> None`.
- Produces: `SnsNotifier.publish(kind: str, target: Target, result: CheckResult, checked_at: str) -> None`.
- Produces: `run(event: dict, repository, notifier, checker, now: datetime) -> dict[str, int]`.
- Produces: AWS entry point `lambda_handler(event: dict, context) -> dict[str, int]`.

- [ ] **Step 1: Write failing orchestration tests with in-memory fakes**

Create `tests/test_handler.py`:

```python
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
```

- [ ] **Step 2: Run the handler tests and confirm failure**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_handler.py -q
```

Expected: FAIL because `url_monitor.handler` does not exist.

- [ ] **Step 3: Add the orchestration function**

Create `lambda/url_monitor/handler.py` with:

```python
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3

from url_monitor.aws_adapters import DynamoStateRepository, SnsNotifier
from url_monitor.checker import check_url
from url_monitor.domain import Target, decide_state

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)


def run(event, repository, notifier, checker, now):
    checked = 0
    errors = []
    threshold = int(event["failure_threshold"])
    expires_at = int((now + timedelta(days=int(event["state_ttl_days"]))).timestamp())
    checked_at = now.isoformat()

    for name, config in event["targets"].items():
        target = Target(
            name=name,
            url=config["url"],
            expected_statuses=frozenset(config["expected_statuses"]),
            timeout_seconds=int(config["timeout_seconds"]),
        )
        try:
            current = repository.get(name)
            result = checker(target)
            decision = decide_state(current, result, threshold, checked_at, expires_at)
            if decision.notification:
                notifier.publish(decision.notification, target, result, checked_at)
            repository.put(name, decision.state)
            LOGGER.info(
                "monitor=%s healthy=%s status=%s response_ms=%s transition=%s",
                name,
                result.healthy,
                decision.state.status,
                result.response_ms,
                decision.notification,
            )
            checked += 1
        except Exception as error:
            LOGGER.exception("monitor=%s internal_error=%s", name, type(error).__name__)
            errors.append(name)

    if errors:
        raise RuntimeError(f"internal monitor failures: {','.join(errors)}")
    return {"checked": checked, "errors": 0}


def lambda_handler(event, _context):
    dynamodb = boto3.resource("dynamodb")
    sns = boto3.client("sns")
    repository = DynamoStateRepository(dynamodb.Table(os.environ["STATE_TABLE_NAME"]))
    notifier = SnsNotifier(sns, os.environ["ALERT_TOPIC_ARN"])
    return run(event, repository, notifier, check_url, datetime.now(timezone.utc))
```

- [ ] **Step 4: Add adapters with explicit serialization**

Create `lambda/url_monitor/aws_adapters.py`:

```python
import json
from dataclasses import asdict

from url_monitor.domain import StoredState


class DynamoStateRepository:
    def __init__(self, table):
        self.table = table

    def get(self, monitor_id: str) -> StoredState | None:
        item = self.table.get_item(Key={"monitor_id": monitor_id}).get("Item")
        if item is None:
            return None
        return StoredState(
            status=item["status"],
            consecutive_failures=int(item["consecutive_failures"]),
            checked_at=item["checked_at"],
            last_changed_at=item["last_changed_at"],
            response_ms=int(item["response_ms"]) if "response_ms" in item else None,
            last_error=item.get("last_error"),
            expires_at=int(item["expires_at"]),
        )

    def put(self, monitor_id: str, state: StoredState) -> None:
        item = {"monitor_id": monitor_id, **asdict(state)}
        self.table.put_item(Item={key: value for key, value in item.items() if value is not None})


class SnsNotifier:
    def __init__(self, client, topic_arn: str):
        self.client = client
        self.topic_arn = topic_arn

    def publish(self, kind, target, result, checked_at) -> None:
        message = {
            "monitor": target.name,
            "url": target.url,
            "transition": kind,
            "checked_at": checked_at,
            "status_code": result.status_code,
            "response_ms": result.response_ms,
            "error_category": result.error_category,
            "error_message": result.error_message,
        }
        self.client.publish(
            TopicArn=self.topic_arn,
            Subject=f"[url-monitor] {kind}: {target.name}",
            Message=json.dumps(message, ensure_ascii=False, indent=2),
        )
```

- [ ] **Step 5: Write and run AWS adapter tests**

Create `tests/test_aws_adapters.py`:

```python
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
```

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_aws_adapters.py -q
```

Expected: PASS with DynamoDB and SNS calls mocked locally.

- [ ] **Step 6: Run orchestration tests**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_handler.py -q
```

Expected: PASS.

- [ ] **Step 7: Add failing isolation and notification-order tests**

Append to `tests/test_handler.py`:

```python
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
```

- [ ] **Step 8: Run the full Python suite**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

Expected: all checker, state, adapter, and orchestration tests PASS.

- [ ] **Step 9: Commit the Lambda application**

Run:

```powershell
git add lambda/url_monitor/aws_adapters.py lambda/url_monitor/handler.py tests/test_aws_adapters.py tests/test_handler.py
git commit -m "feat: orchestrate monitor state and notifications"
```

Expected: Lambda behavior is complete and testable without AWS.

---

### Task 4: Reusable Terraform Monitor Module

**Files:**
- Create: `.tflint.hcl`
- Create: `modules/url-monitor/versions.tf`
- Create: `modules/url-monitor/variables.tf`
- Create: `modules/url-monitor/iam.tf`
- Create: `modules/url-monitor/main.tf`
- Create: `modules/url-monitor/outputs.tf`
- Create: `modules/url-monitor/tests/module.tftest.hcl`

**Interfaces:**
- Consumes: packaged Lambda `{ filename: string, source_code_hash: string }`.
- Consumes: `monitor_targets`, `alert_email`, `schedule_expression`, `failure_threshold`, and `log_retention_days`.
- Produces: `lambda_function_name`, `state_table_name`, `sns_topic_arn`, `schedule_name`, and `log_group_name`.

- [ ] **Step 1: Add Terraform and lint constraints**

Create `.tflint.hcl`:

```hcl
config {
  call_module_type = "all"
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}
```

Create `modules/url-monitor/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
  }
}
```

- [ ] **Step 2: Write mocked-provider tests before module resources**

Create `modules/url-monitor/tests/module.tftest.hcl`:

```hcl
mock_provider "aws" {}

variables {
  project_name = "url-monitor"
  alert_email  = "alerts@example.com"
  monitor_targets = {
    demo = {
      url               = "https://example.com"
      expected_statuses = [200]
      timeout_seconds   = 5
    }
  }
  lambda_package = {
    filename         = "fixture.zip"
    source_code_hash = "ZmFrZS1oYXNo"
  }
}

run "plans_low_cost_runtime" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.state.billing_mode == "PAY_PER_REQUEST"
    error_message = "DynamoDB must use on-demand capacity."
  }

  assert {
    condition     = aws_lambda_function.checker.timeout == 30
    error_message = "Lambda timeout must remain 30 seconds."
  }

  assert {
    condition     = aws_cloudwatch_log_group.checker.retention_in_days == 7
    error_message = "Log retention must default to seven days."
  }
}

run "rejects_six_targets" {
  command = plan

  variables {
    monitor_targets = {
      one   = { url = "https://example.com/1" }
      two   = { url = "https://example.com/2" }
      three = { url = "https://example.com/3" }
      four  = { url = "https://example.com/4" }
      five  = { url = "https://example.com/5" }
      six   = { url = "https://example.com/6" }
    }
  }

  expect_failures = [var.monitor_targets]
}
```

- [ ] **Step 3: Run the module test and confirm failure**

Run:

```powershell
terraform -chdir=modules/url-monitor init -backend=false
terraform -chdir=modules/url-monitor test
```

Expected: FAIL because variables and resources do not exist.

- [ ] **Step 4: Add fully validated module inputs**

Create `modules/url-monitor/variables.tf`:

```hcl
variable "project_name" {
  description = "Prefix used for every project resource."
  type        = string
  default     = "url-monitor"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.project_name))
    error_message = "project_name must be 3-32 lowercase letters, numbers, or hyphens."
  }
}

variable "alert_email" {
  description = "Email subscribed to monitor alerts."
  type        = string
  sensitive   = true
}

variable "monitor_targets" {
  description = "Public HTTP(S) endpoints keyed by stable monitor ID."
  type = map(object({
    url               = string
    expected_statuses = optional(set(number), [200])
    timeout_seconds   = optional(number, 5)
  }))

  validation {
    condition     = length(var.monitor_targets) >= 1 && length(var.monitor_targets) <= 5
    error_message = "monitor_targets must contain one through five endpoints."
  }

  validation {
    condition = alltrue([
      for target in values(var.monitor_targets) :
      can(regex("^https?://", target.url)) &&
      length(target.expected_statuses) > 0 &&
      target.timeout_seconds >= 1 &&
      target.timeout_seconds <= 5
    ])
    error_message = "Each target needs HTTP(S), at least one expected status, and a 1-5 second timeout."
  }
}

variable "lambda_package" {
  description = "Prepared Lambda zip file and its base64 SHA-256."
  type = object({
    filename         = string
    source_code_hash = string
  })
}

variable "schedule_expression" {
  description = "EventBridge Scheduler rate expression."
  type        = string
  default     = "rate(5 minutes)"
}

variable "failure_threshold" {
  description = "Consecutive failures required before outage notification."
  type        = number
  default     = 2

  validation {
    condition     = var.failure_threshold >= 1
    error_message = "failure_threshold must be at least one."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags added to taggable project resources."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 5: Add runtime IAM roles with exact service boundaries**

Create `modules/url-monitor/iam.tf` with:

```hcl
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.checker.arn}:*"]
  }
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.state.arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.project_name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.project_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.checker.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${var.project_name}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}
```

- [ ] **Step 6: Add the serverless runtime resources**

Create `modules/url-monitor/main.tf` with these concrete resources:

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_dynamodb_table" "state" {
  name         = "${var.project_name}-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "monitor_id"

  attribute {
    name = "monitor_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "checker" {
  name              = "/aws/lambda/${var.project_name}-checker"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "checker" {
  function_name    = "${var.project_name}-checker"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "url_monitor.handler.lambda_handler"
  filename         = var.lambda_package.filename
  source_code_hash = var.lambda_package.source_code_hash
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      STATE_TABLE_NAME = aws_dynamodb_table.state.name
      ALERT_TOPIC_ARN  = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.checker, aws_iam_role_policy.lambda]
  tags       = var.tags
}

resource "aws_scheduler_schedule_group" "monitor" {
  name = var.project_name
  tags = var.tags
}

resource "aws_scheduler_schedule" "monitor" {
  name       = "${var.project_name}-checks"
  group_name = aws_scheduler_schedule_group.monitor.name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = var.schedule_expression

  target {
    arn      = aws_lambda_function.checker.arn
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      failure_threshold = var.failure_threshold
      state_ttl_days    = 7
      targets = {
        for name, target in var.monitor_targets : name => {
          url               = target.url
          expected_statuses = tolist(target.expected_statuses)
          timeout_seconds   = target.timeout_seconds
        }
      }
    })

    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.checker.function_name
  }

  tags = var.tags
}
```

- [ ] **Step 7: Add documented module outputs**

Create `modules/url-monitor/outputs.tf`:

```hcl
output "lambda_function_name" {
  description = "Lambda function that executes URL checks."
  value       = aws_lambda_function.checker.function_name
}

output "state_table_name" {
  description = "DynamoDB table holding current monitor state."
  value       = aws_dynamodb_table.state.name
}

output "sns_topic_arn" {
  description = "SNS topic used for monitor notifications."
  value       = aws_sns_topic.alerts.arn
}

output "schedule_name" {
  description = "EventBridge Scheduler schedule name."
  value       = aws_scheduler_schedule.monitor.name
}

output "log_group_name" {
  description = "CloudWatch log group for the monitor Lambda."
  value       = aws_cloudwatch_log_group.checker.name
}
```

- [ ] **Step 8: Run formatting, validation, mocked tests, and TFLint**

Run:

```powershell
terraform fmt -recursive
terraform -chdir=modules/url-monitor init -backend=false
terraform -chdir=modules/url-monitor validate
terraform -chdir=modules/url-monitor test
tflint --init
tflint --recursive --format compact
```

Expected: every command exits zero; mocked tests verify on-demand DynamoDB, an unreserved 30-second Lambda, seven-day logs, and target-count validation. The 30-second maximum runtime is much shorter than the five-minute schedule interval, which operationally bounds overlap for normal scheduled runs without requiring a per-function concurrency reservation.

- [ ] **Step 9: Commit the reusable module**

Run:

```powershell
git add .tflint.hcl modules/url-monitor
git commit -m "feat: add serverless URL monitor module"
```

Expected: the module is reviewable without bootstrap or a live AWS account.

---

### Task 5: Bootstrap State, Budget, and GitHub OIDC

**Files:**
- Create: `bootstrap/backend.tf`
- Create: `bootstrap/versions.tf`
- Create: `bootstrap/variables.tf`
- Create: `bootstrap/main.tf`
- Create: `bootstrap/oidc.tf`
- Create: `bootstrap/outputs.tf`
- Create: `bootstrap/tests/bootstrap.tftest.hcl`

**Interfaces:**
- Consumes: GitHub owner/repository names and immutable IDs, fixed repository name `terraform-aws-url-monitor`, and `alert_email`.
- Produces: `state_bucket_name`, `aws_account_id`, `plan_role_arn`, and `deploy_role_arn`.

- [ ] **Step 1: Ensure the portfolio repository identity exists**

Run:

```powershell
gh auth status
$projectOwner = gh api user --jq .login
gh repo view "$projectOwner/terraform-aws-url-monitor"
```

Expected: GitHub authentication succeeds. If the final command reports that the repository does not exist, create the approved public portfolio repository and push the existing commits:

```powershell
gh repo create terraform-aws-url-monitor --public --source . --remote origin --push
```

- [ ] **Step 2: Write bootstrap tests first**

Create `bootstrap/tests/bootstrap.tftest.hcl`:

```hcl
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  github_owner         = "portfolio-owner"
  github_owner_id      = "123456789"
  github_repository    = "terraform-aws-url-monitor"
  github_repository_id = "987654321"
  alert_email          = "alerts@example.com"
}

run "plans_safe_bootstrap" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket versioning must be enabled."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls
    error_message = "State bucket public ACLs must be blocked."
  }

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "5"
    error_message = "Monthly budget must remain USD 5."
  }
}
```

- [ ] **Step 3: Add bootstrap constraints and variables**

Keep bootstrap on local state until its state bucket exists. The partial backend block is added immediately before migration in Step 9.

Create `bootstrap/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}
```

Create `bootstrap/variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region for project resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project resource prefix."
  type        = string
  default     = "url-monitor"
}

variable "github_owner" {
  description = "GitHub account that owns the repository."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub account ID used in OIDC subjects."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be a numeric GitHub account ID."
  }
}

variable "github_repository" {
  description = "GitHub repository trusted by AWS."
  type        = string
  default     = "terraform-aws-url-monitor"
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID used in OIDC subjects."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be a numeric GitHub repository ID."
  }
}

variable "alert_email" {
  description = "Email receiving the AWS monthly budget notification."
  type        = string
  sensitive   = true
}
```

- [ ] **Step 4: Add encrypted, versioned S3 state and the USD 5 budget**

Create `bootstrap/main.tf`:

```hcl
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
```

- [ ] **Step 5: Add GitHub OIDC trust and state access**

Create the OIDC provider and shared state policy in `bootstrap/oidc.tf`:

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = { Name = "${var.project_name}-github" }
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "${aws_s3_bucket.state.arn}/infra/terraform.tfstate",
    ]
  }
  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.state.arn}/infra/terraform.tfstate.tflock",
    ]
  }
}

resource "aws_iam_policy" "state_access" {
  name   = "${var.project_name}-terraform-state"
  policy = data.aws_iam_policy_document.state_access.json
}
```

Add separate trust policies:

```hcl
data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:production"]
    }
  }
}
```

- [ ] **Step 6: Add plan and deploy permissions**

Continue `bootstrap/oidc.tf`:

```hcl
resource "aws_iam_role" "plan" {
  name               = "${var.project_name}-github-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "plan_state" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

resource "aws_iam_role" "deploy" {
  name               = "${var.project_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    actions = [
      "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction",
      "lambda:GetFunctionCodeSigningConfig", "lambda:GetPolicy", "lambda:ListTags",
      "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
      "lambda:TagResource", "lambda:UntagResource", "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration"
    ]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-*"]
  }

  statement {
    actions = [
      "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTable", "dynamodb:DescribeTimeToLive", "dynamodb:ListTagsOfResource",
      "dynamodb:TagResource", "dynamodb:UntagResource", "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive"
    ]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project_name}-*"]
  }

  statement {
    actions = [
      "sns:CreateTopic", "sns:DeleteTopic", "sns:GetSubscriptionAttributes",
      "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic", "sns:ListTagsForResource",
      "sns:SetTopicAttributes", "sns:Subscribe", "sns:TagResource", "sns:Unsubscribe",
      "sns:UntagResource"
    ]
    resources = ["arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-*"]
  }

  statement {
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
      "logs:ListTagsForResource", "logs:PutRetentionPolicy", "logs:TagResource",
      "logs:UntagResource"
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-*"]
  }

  statement {
    actions = [
      "scheduler:CreateSchedule", "scheduler:CreateScheduleGroup", "scheduler:DeleteSchedule",
      "scheduler:DeleteScheduleGroup", "scheduler:GetSchedule", "scheduler:GetScheduleGroup",
      "scheduler:ListTagsForResource", "scheduler:TagResource", "scheduler:UntagResource",
      "scheduler:UpdateSchedule"
    ]
    resources = [
      "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/${var.project_name}/${var.project_name}-*",
      "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule-group/${var.project_name}",
    ]
  }

  statement {
    actions = [
      "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
      "cloudwatch:PutMetricAlarm", "cloudwatch:TagResource", "cloudwatch:UntagResource"
    ]
    resources = ["arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-*"]
  }

  statement {
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:GetRole",
      "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies", "iam:ListRoleTags", "iam:PutRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy"
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "scheduler.amazonaws.com"]
    }
  }

  statement {
    actions = [
      "cloudwatch:DescribeAlarms",
      "dynamodb:ListTables",
      "iam:ListRoles",
      "lambda:GetAccountSettings",
      "lambda:ListFunctions",
      "logs:DescribeLogGroups",
      "scheduler:ListScheduleGroups",
      "scheduler:ListSchedules",
      "sns:ListSubscriptions",
      "sns:ListTopics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = "${var.project_name}-github-deploy"
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy_attachment" "deploy_project" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}

resource "aws_iam_role_policy_attachment" "deploy_state" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.state_access.arn
}

data "aws_iam_policy_document" "github_state_boundary" {
  statement {
    sid    = "DenyGitHubBootstrapStateObjects"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.plan.arn, aws_iam_role.deploy.arn]
    }
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/bootstrap/*"]
  }

  statement {
    sid    = "DenyGitHubBootstrapStateListing"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.plan.arn, aws_iam_role.deploy.arn]
    }
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["bootstrap/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.github_state_boundary.json
}
```

- [ ] **Step 7: Add outputs and run mocked bootstrap tests**

Create `bootstrap/outputs.tf`:

```hcl
output "state_bucket_name" {
  description = "Versioned S3 bucket holding Terraform state."
  value       = aws_s3_bucket.state.id
}

output "aws_account_id" {
  description = "AWS account used by GitHub credential validation."
  value       = data.aws_caller_identity.current.account_id
}

output "plan_role_arn" {
  description = "Read-only GitHub OIDC role for Terraform plan."
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "Approved GitHub OIDC role for Terraform apply."
  value       = aws_iam_role.deploy.arn
}
```

Run:

```powershell
terraform fmt -recursive
terraform -chdir=bootstrap init -backend=false
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap test
```

Expected: PASS without creating AWS resources.

- [ ] **Step 8: Apply bootstrap locally with non-root credentials**

Run these identity checks first:

```powershell
aws sts get-caller-identity
$projectOwner = gh api user --jq .login
$projectOwnerId = gh api user --jq .id
$projectRepository = "terraform-aws-url-monitor"
$projectRepositoryId = gh api "repos/$projectOwner/$projectRepository" --jq .id
$env:TF_VAR_github_owner = $projectOwner
$env:TF_VAR_github_owner_id = $projectOwnerId
$env:TF_VAR_github_repository = $projectRepository
$env:TF_VAR_github_repository_id = $projectRepositoryId
$env:TF_VAR_alert_email = Read-Host 'Email for AWS budget and monitor alerts'
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
```

Expected: the caller is not the root user; plan creates only S3, AWS Budget, IAM OIDC, IAM roles, and policies; apply succeeds. Confirm the budget email is received.

- [ ] **Step 9: Migrate bootstrap state into its S3 backend**

Create `bootstrap/backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

Then run:

```powershell
$stateBucket = terraform -chdir=bootstrap output -raw state_bucket_name
terraform -chdir=bootstrap init -migrate-state `
  -backend-config="bucket=$stateBucket" `
  -backend-config="key=bootstrap/terraform.tfstate" `
  -backend-config="region=ap-northeast-2" `
  -backend-config="encrypt=true" `
  -backend-config="use_lockfile=true"
terraform -chdir=bootstrap state list
```

Expected: migration confirmation succeeds and `state list` reads all bootstrap resources from S3.

- [ ] **Step 10: Commit bootstrap code without local state**

Run:

```powershell
git status --short
git add bootstrap
git commit -m "feat: bootstrap remote state and GitHub OIDC"
```

Expected: no state, plan, email, or backend configuration value is staged.

---

### Task 6: Live Root and Approved GitHub Delivery

**Files:**
- Create: `infra/backend.tf`
- Create: `infra/versions.tf`
- Create: `infra/variables.tf`
- Create: `infra/package.tf`
- Create: `infra/main.tf`
- Create: `infra/monitor.auto.tfvars.json`
- Create: `infra/outputs.tf`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: S3 bucket and OIDC role ARNs from Task 5.
- Consumes: GitHub repository secret `ALERT_EMAIL`.
- Produces: a credential-free CI workflow and a manual plan/approval/apply workflow.

- [ ] **Step 1: Write the live Terraform root**

Create `infra/backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

Create `infra/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.8.0, < 3.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "url-monitor"
      Environment = "production"
      ManagedBy   = "Terraform"
    }
  }
}
```

Create `infra/variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region for the monitor."
  type        = string
  default     = "ap-northeast-2"
}

variable "alert_email" {
  description = "Email receiving outage and recovery alerts."
  type        = string
  sensitive   = true
}

variable "monitor_targets" {
  description = "Public endpoints passed to the monitor module."
  type = map(object({
    url               = string
    expected_statuses = optional(set(number), [200])
    timeout_seconds   = optional(number, 5)
  }))
}
```

- [ ] **Step 2: Package Lambda and call the module**

Create `infra/package.tf`:

```hcl
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/url-monitor.zip"
}
```

Create `infra/main.tf`:

```hcl
module "url_monitor" {
  source = "../modules/url-monitor"

  project_name    = "url-monitor"
  alert_email     = var.alert_email
  monitor_targets = var.monitor_targets
  lambda_package = {
    filename         = data.archive_file.lambda.output_path
    source_code_hash = data.archive_file.lambda.output_base64sha256
  }

  schedule_expression = "rate(5 minutes)"
  failure_threshold   = 2
  log_retention_days  = 7
}
```

Create `infra/monitor.auto.tfvars.json`:

```json
{
  "monitor_targets": {
    "demo": {
      "url": "https://example.com",
      "expected_statuses": [200],
      "timeout_seconds": 5
    }
  }
}
```

Create `infra/outputs.tf`:

```hcl
output "lambda_function_name" {
  description = "Lambda function that executes checks."
  value       = module.url_monitor.lambda_function_name
}

output "state_table_name" {
  description = "DynamoDB table holding current state."
  value       = module.url_monitor.state_table_name
}

output "sns_topic_arn" {
  description = "SNS topic requiring email confirmation."
  value       = module.url_monitor.sns_topic_arn
}

output "schedule_name" {
  description = "EventBridge Scheduler schedule."
  value       = module.url_monitor.schedule_name
}

output "log_group_name" {
  description = "CloudWatch log group."
  value       = module.url_monitor.log_group_name
}
```

- [ ] **Step 3: Validate the live root without AWS credentials**

Run:

```powershell
terraform fmt -recursive
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
.\.venv\Scripts\python.exe -m pytest -q
terraform -chdir=modules/url-monitor test
tflint --recursive --format compact
```

Expected: all commands PASS; no AWS resource is created.

- [ ] **Step 4: Add the credential-free CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6.0.2
      - uses: hashicorp/setup-terraform@v4.0.1
        with:
          terraform_version: 1.16.0
      - uses: terraform-linters/setup-tflint@v6.2.2
        with:
          tflint_version: v0.64.0
          cache: true
      - uses: actions/setup-python@v6
        with:
          python-version: "3.13"
          cache: pip
      - run: pip install -r requirements-dev.txt
      - run: pytest -q
      - run: terraform fmt -check -recursive
      - run: terraform -chdir=bootstrap init -backend=false
      - run: terraform -chdir=bootstrap validate
      - run: terraform -chdir=bootstrap test
      - run: terraform -chdir=infra init -backend=false
      - run: terraform -chdir=infra validate
      - run: terraform -chdir=modules/url-monitor init -backend=false
      - run: terraform -chdir=modules/url-monitor test
      - run: tflint --init
        env:
          GITHUB_TOKEN: ${{ github.token }}
      - run: tflint --recursive --format compact
```

- [ ] **Step 5: Add the exact-plan approved deployment workflow**

Create `.github/workflows/deploy.yml`:

```yaml
name: Terraform Deploy

on:
  workflow_dispatch:
    inputs:
      operation:
        description: Terraform operation
        required: true
        default: apply
        type: choice
        options: [apply, destroy]

permissions:
  contents: read
  id-token: write

env:
  TF_IN_AUTOMATION: "true"
  TF_VAR_alert_email: ${{ secrets.ALERT_EMAIL }}
  AWS_REGION: ap-northeast-2

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6.0.2
      - uses: hashicorp/setup-terraform@v4.0.1
        with:
          terraform_version: 1.16.0
      - uses: aws-actions/configure-aws-credentials@v6.2.3
        with:
          role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
          allowed-account-ids: ${{ vars.AWS_ACCOUNT_ID }}
          role-session-name: url-monitor-plan
      - name: Initialize backend
        run: >-
          terraform -chdir=infra init -input=false
          -backend-config="bucket=${{ vars.TF_STATE_BUCKET }}"
          -backend-config="key=infra/terraform.tfstate"
          -backend-config="region=${{ env.AWS_REGION }}"
          -backend-config="encrypt=true"
          -backend-config="use_lockfile=true"
      - name: Create saved plan
        shell: bash
        run: |
          if [[ "${{ inputs.operation }}" == "destroy" ]]; then
            terraform -chdir=infra plan -destroy -input=false -out=tfplan
          else
            terraform -chdir=infra plan -input=false -out=tfplan
          fi
          terraform -chdir=infra show -no-color tfplan > infra/plan.txt
          cat infra/plan.txt >> "$GITHUB_STEP_SUMMARY"
      - uses: actions/upload-artifact@v7.0.1
        with:
          name: terraform-plan
          path: |
            infra/tfplan
            infra/plan.txt
          retention-days: 1
          if-no-files-found: error

  apply:
    needs: plan
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v6.0.2
      - uses: actions/download-artifact@v8
        with:
          name: terraform-plan
          path: infra
      - uses: hashicorp/setup-terraform@v4.0.1
        with:
          terraform_version: 1.16.0
      - uses: aws-actions/configure-aws-credentials@v6.2.3
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
          allowed-account-ids: ${{ vars.AWS_ACCOUNT_ID }}
          role-session-name: url-monitor-deploy
      - name: Initialize backend
        run: >-
          terraform -chdir=infra init -input=false
          -backend-config="bucket=${{ vars.TF_STATE_BUCKET }}"
          -backend-config="key=infra/terraform.tfstate"
          -backend-config="region=${{ env.AWS_REGION }}"
          -backend-config="encrypt=true"
          -backend-config="use_lockfile=true"
      - name: Apply reviewed plan
        run: terraform -chdir=infra apply -input=false tfplan
```

- [ ] **Step 6: Configure GitHub variables, secret, and approval**

Initialize the live root against the new backend, then configure GitHub:

```powershell
$stateBucket = terraform -chdir=bootstrap output -raw state_bucket_name
terraform -chdir=infra init -reconfigure `
  -backend-config="bucket=$stateBucket" `
  -backend-config="key=infra/terraform.tfstate" `
  -backend-config="region=ap-northeast-2" `
  -backend-config="encrypt=true" `
  -backend-config="use_lockfile=true"
$accountId = terraform -chdir=bootstrap output -raw aws_account_id
$planRole = terraform -chdir=bootstrap output -raw plan_role_arn
$deployRole = terraform -chdir=bootstrap output -raw deploy_role_arn
gh variable set TF_STATE_BUCKET --body $stateBucket
gh variable set AWS_ACCOUNT_ID --body $accountId
gh variable set AWS_PLAN_ROLE_ARN --body $planRole
gh variable set AWS_DEPLOY_ROLE_ARN --body $deployRole
$alertEmail = Read-Host 'Email for outage and recovery alerts'
$alertEmail | gh secret set ALERT_EMAIL
```

In GitHub repository settings, create the `production` environment, restrict deployment branches to `main`, and add the repository owner as a required reviewer. This approval must exist before the first deploy workflow is run.

- [ ] **Step 7: Commit and push CI/CD and the live root**

Run:

```powershell
git add infra .github/workflows
git commit -m "feat: add approved Terraform delivery workflow"
git push origin main
gh run list --workflow ci.yml --limit 1
```

Expected: the pushed CI run completes successfully and no AWS monitor resource exists before the manual deploy.

---

### Task 7: End-to-End Incident Demonstration and Runbook

**Files:**
- Create: `README.md`
- Create: `docs/runbook.md`
- Modify: `infra/monitor.auto.tfvars.json`

**Interfaces:**
- Consumes: deployment workflow and AWS outputs from Task 6.
- Produces: verified outage/recovery evidence, a clean healthy final configuration, and operator documentation.

- [ ] **Step 1: Trigger the first approved deployment**

Run:

```powershell
gh workflow run deploy.yml -f operation=apply
gh run list --workflow deploy.yml --limit 1
```

Open the newest run, review the human-readable plan, verify that it contains only the approved serverless resources, then approve the `production` environment job.

Expected: apply succeeds. Click the SNS confirmation link sent by AWS before evaluating alerts.

- [ ] **Step 2: Verify healthy runtime state**

Run:

```powershell
$tableName = terraform -chdir=infra output -raw state_table_name
$logGroup = terraform -chdir=infra output -raw log_group_name
aws dynamodb get-item --region ap-northeast-2 --table-name $tableName --key '{"monitor_id":{"S":"demo"}}'
aws logs tail $logGroup --region ap-northeast-2 --since 15m
```

Expected: DynamoDB reports `status` as `UP`; logs show successful checks with HTTP 200 and response time. No outage email is sent.

- [ ] **Step 3: Create the deliberate DNS-failure change**

Change only the URL in `infra/monitor.auto.tfvars.json`:

```json
{
  "monitor_targets": {
    "demo": {
      "url": "https://monitor-demo.invalid",
      "expected_statuses": [200],
      "timeout_seconds": 5
    }
  }
}
```

Run:

```powershell
git switch -c codex/demonstrate-outage
git add infra/monitor.auto.tfvars.json
git commit -m "test: simulate monitored endpoint outage"
git push -u origin codex/demonstrate-outage
gh pr create --fill
```

Expected: pull-request CI passes. Merge the pull request only after reviewing its one-line infrastructure input change.

- [ ] **Step 4: Deploy the failure and verify one normal outage transition**

After merging, run:

```powershell
git switch main
git pull --ff-only
gh workflow run deploy.yml -f operation=apply
```

Review and approve the plan. Wait for two scheduled checks, then run:

```powershell
$tableName = terraform -chdir=infra output -raw state_table_name
$logGroup = terraform -chdir=infra output -raw log_group_name
aws dynamodb get-item --region ap-northeast-2 --table-name $tableName --key '{"monitor_id":{"S":"demo"}}'
aws logs tail $logGroup --region ap-northeast-2 --since 20m
```

Expected: first failure stores `PENDING_DOWN`, second stores `DOWN`, one outage email arrives, and additional normal checks do not send another outage email.

- [ ] **Step 5: Restore the healthy endpoint and verify recovery**

Restore `https://example.com` in `infra/monitor.auto.tfvars.json`, then run:

```powershell
git switch -c codex/restore-monitor
git add infra/monitor.auto.tfvars.json
git commit -m "fix: restore healthy monitor target"
git push -u origin codex/restore-monitor
gh pr create --fill
```

After CI passes, merge, update local `main`, run the approved deploy workflow, and wait for one scheduled check.

Expected: DynamoDB returns to `UP` and one recovery email arrives in the normal execution path.

- [ ] **Step 6: Write the portfolio README**

Create `README.md` with these sections and verified values from the run:

```markdown
# Terraform AWS URL Monitor

A low-cost, serverless URL monitor provisioned and operated with Terraform.

## What it demonstrates

- Reusable Terraform modules and validated inputs
- Versioned S3 remote state with native locking
- GitHub OIDC instead of stored AWS keys
- Pull-request checks and human-approved exact-plan deployment
- Least-privilege runtime IAM
- Stateful outage suppression and recovery alerts

## Architecture

EventBridge Scheduler → Lambda → DynamoDB
                              ↘ SNS email
Lambda Errors → CloudWatch Alarm → SNS email

## Normal behavior

The monitor checks one to five public HTTP(S) targets every five minutes.
Two consecutive failures create one outage alert. A subsequent success creates
one recovery alert. Continued failures do not create repeated normal alerts.

## Cost controls

The design uses no VPC, NAT Gateway, EC2, load balancer, RDS, custom metrics,
or public IPv4 address. Logs expire after seven days and the AWS account has a
USD 5 monthly budget notification.

## Repository layout

- `bootstrap/`: remote state, budget, and GitHub OIDC
- `infra/`: live root configuration
- `modules/url-monitor/`: reusable AWS monitor module
- `lambda/url_monitor/`: tested Python monitor
- `.github/workflows/`: CI and approved deployment

## Verification

The acceptance run demonstrated `UP → PENDING_DOWN → DOWN → UP`, one normal
outage email, no repeated normal outage email, and one recovery email.

See `docs/runbook.md` for setup, operations, troubleshooting, and teardown.
```

- [ ] **Step 7: Write the operating runbook**

Create `docs/runbook.md`:

```markdown
# URL Monitor Runbook

## Change a target

Edit `infra/monitor.auto.tfvars.json` while keeping the stable map key. Open a
pull request, require CI to pass, merge to `main`, and manually run
`Terraform Deploy` with operation `apply`. Review the saved plan before
approving the `production` job.

## Confirm alert delivery

The SNS subscription is incomplete until the AWS confirmation link is clicked.

    $topicArn = terraform -chdir=infra output -raw sns_topic_arn
    aws sns list-subscriptions-by-topic --topic-arn $topicArn

The subscription ARN must not be `PendingConfirmation`.

## Inspect current state

    $tableName = terraform -chdir=infra output -raw state_table_name
    aws dynamodb get-item --region ap-northeast-2 --table-name $tableName --key '{"monitor_id":{"S":"demo"}}'

`UP`, `PENDING_DOWN`, and `DOWN` are the only valid states.

## Inspect execution

    $logGroup = terraform -chdir=infra output -raw log_group_name
    aws logs tail $logGroup --region ap-northeast-2 --since 30m --follow

## Diagnose missing notifications

1. Confirm the SNS subscription is not pending.
2. Confirm Lambda logs contain the expected state transition.
3. Inspect the `url-monitor-lambda-errors` CloudWatch alarm.
4. Confirm the Lambda role can publish to `url-monitor-alerts`.
5. Run the approved deploy workflow and verify Terraform reports no drift.

## Destroy runtime resources

Run `Terraform Deploy` with operation `destroy`, review the saved destroy plan,
and approve the `production` job. This removes runtime resources but retains
the bootstrap state bucket, budget, and GitHub OIDC roles.

## Full bootstrap teardown

Full teardown is exceptional because the state bucket uses `prevent_destroy`.

1. Destroy runtime resources first.
2. Migrate bootstrap state back to local storage.
3. Read and verify the exact bucket name from `terraform output`.
4. Remove `prevent_destroy` in a reviewed commit.
5. Remove every object version through the AWS console for that exact bucket.
6. Create and review a bootstrap destroy plan before applying it.

Never use a wildcard, unresolved variable, home directory, or workspace root as
a deletion target.
```

- [ ] **Step 8: Run the final verification suite and drift check**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest -q
terraform fmt -check -recursive
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap test
terraform -chdir=infra validate
terraform -chdir=modules/url-monitor test
tflint --recursive --format compact
$stateBucket = terraform -chdir=bootstrap output -raw state_bucket_name
$env:TF_VAR_alert_email = Read-Host 'Alert email for final no-drift plan'
terraform -chdir=infra init -reconfigure -input=false `
  -backend-config="bucket=$stateBucket" `
  -backend-config="key=infra/terraform.tfstate" `
  -backend-config="region=ap-northeast-2" `
  -backend-config="encrypt=true" `
  -backend-config="use_lockfile=true"
terraform -chdir=infra plan -detailed-exitcode
```

Expected: tests, formatting, validation, and lint exit zero; the final plan reports no changes and exits zero.

- [ ] **Step 9: Commit the verified documentation**

Run:

```powershell
git add README.md docs/runbook.md infra/monitor.auto.tfvars.json
git commit -m "docs: add verified monitor runbook"
git push origin main
git status --short
```

Expected: the final configuration monitors `https://example.com`, the worktree is clean, CI passes, and the monitor remains available for future personal targets.
