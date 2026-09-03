# URL Monitor Check History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every completed URL check in a queryable seven-day DynamoDB history table without changing the existing outage and recovery state machine.

**Architecture:** Keep the current-state table untouched and add a separate on-demand DynamoDB table keyed by `monitor_id` and `checked_at`. Lambda writes current state first and then one compact history item; Terraform supplies the table name and retention value, limits runtime access to `PutItem`, and keeps the live Scheduler explicitly disabled.

**Tech Stack:** Terraform 1.16.0, HashiCorp AWS provider 6.x, AWS Lambda Python 3.13, DynamoDB, pytest, TFLint, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-03-url-monitor-check-history-design.md`

## Global Constraints

- Deploy only to AWS region `ap-northeast-2`.
- Do not replace or change the key schema of the existing `${project_name}-state` table.
- Create `${project_name}-history` with `PAY_PER_REQUEST`, partition key `monitor_id`, sort key `checked_at`, and TTL attribute `expires_at`.
- Retain history for seven days; DynamoDB TTL deletion is asynchronous.
- Store no target URL or full error message in history.
- Preserve the existing state-transition and notification ordering.
- Write current state before history; a history failure must fail the invocation after other targets are processed.
- Grant Lambda only `dynamodb:PutItem` on the history table.
- Keep the live Scheduler disabled until the user explicitly enables it through a reviewed deployment.
- Do not add RDS, indexes, streams, backups, point-in-time recovery, dashboards, or new runtime dependencies.
- Do not deploy, push, merge, or enable the live schedule as part of this plan execution.

---

### Task 1: Python History Repository and Runtime Orchestration

**Files:**
- Modify: `lambda/url_monitor/aws_adapters.py`
- Modify: `lambda/url_monitor/handler.py`
- Modify: `tests/test_aws_adapters.py`
- Modify: `tests/test_handler.py`

**Interfaces:**
- Consumes: existing `CheckResult`, `StoredState`, `DynamoStateRepository`, `SnsNotifier`, and `decide_state` behavior.
- Produces: `DynamoHistoryRepository.put(monitor_id: str, checked_at: str, result: CheckResult, state: StoredState, expires_at: int) -> None`.
- Changes: `run(event, repository, history_repository, notifier, checker, now) -> dict[str, int]`.
- Consumes new event key: `history_ttl_days` as an integer number of days.
- Consumes new environment variable: `HISTORY_TABLE_NAME`.

- [ ] **Step 1: Add failing history serialization tests**

Update the imports in `tests/test_aws_adapters.py` to include `DynamoHistoryRepository`, then add these tests:

```python
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
```

- [ ] **Step 2: Run the focused adapter tests and confirm the expected failure**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_aws_adapters.py -q
```

Expected: collection fails because `DynamoHistoryRepository` does not exist.

- [ ] **Step 3: Implement the minimal DynamoDB history adapter**

Change the domain import in `lambda/url_monitor/aws_adapters.py` and add the repository before `SnsNotifier`:

```python
from url_monitor.domain import CheckResult, StoredState


class DynamoHistoryRepository:
    def __init__(self, table):
        self.table = table

    def put(
        self,
        monitor_id: str,
        checked_at: str,
        result: CheckResult,
        state: StoredState,
        expires_at: int,
    ) -> None:
        item = {
            "monitor_id": monitor_id,
            "checked_at": checked_at,
            "healthy": result.healthy,
            "state": state.status,
            "status_code": result.status_code,
            "response_ms": result.response_ms,
            "error_category": result.error_category,
            "expires_at": expires_at,
        }
        self.table.put_item(Item={key: value for key, value in item.items() if value is not None})
```

Do not add `url` or `error_message` fields.

- [ ] **Step 4: Run the adapter tests and verify they pass**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_aws_adapters.py -q
```

Expected: all adapter tests pass.

- [ ] **Step 5: Add failing orchestration tests and update existing calls to the new interface**

Add `"history_ttl_days": 7` to `EVENT` in `tests/test_handler.py`. Add a history fake after `MemoryRepository`:

```python
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
```

Add an optional `operations` argument to `MemoryRepository`, and append `(\"state\", monitor_id)` in its `put` method. Update every existing `run(...)` call so a `MemoryHistoryRepository()` is passed immediately after the current-state repository.

Add these focused tests:

```python
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
```

Import `timedelta` beside `datetime` and `timezone`. In both `test_one_internal_error_does_not_skip_remaining_target` and `test_malformed_target_does_not_skip_remaining_target`, create `history = MemoryHistoryRepository()`, pass it after `repository`, and add:

```python
assert [item[0] for item in history.items] == ["healthy"]
```

This proves an exception before a completed result creates no history record while the later healthy target still does.

- [ ] **Step 6: Run the handler tests and confirm the expected interface failure**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_handler.py -q
```

Expected: tests fail because `run` does not accept or use the history repository.

- [ ] **Step 7: Implement history orchestration and Lambda wiring**

Update `lambda/url_monitor/handler.py` as follows:

```python
from url_monitor.aws_adapters import DynamoHistoryRepository, DynamoStateRepository, SnsNotifier


def run(event, repository, history_repository, notifier, checker, now):
    checked = 0
    errors = []
    threshold = int(event["failure_threshold"])
    expires_at = int((now + timedelta(days=int(event["state_ttl_days"]))).timestamp())
    history_expires_at = int(
        (now + timedelta(days=int(event["history_ttl_days"]))).timestamp()
    )
    checked_at = now.isoformat()
```

Keep the existing loop and notification behavior, but add this call immediately after `repository.put(name, decision.state)` and before the success log/counter:

```python
history_repository.put(name, checked_at, result, decision.state, history_expires_at)
```

Update `lambda_handler` to create both repositories and use the new `run` signature:

```python
def lambda_handler(event, _context):
    dynamodb = boto3.resource("dynamodb")
    sns = boto3.client("sns")
    repository = DynamoStateRepository(dynamodb.Table(os.environ["STATE_TABLE_NAME"]))
    history_repository = DynamoHistoryRepository(
        dynamodb.Table(os.environ["HISTORY_TABLE_NAME"])
    )
    notifier = SnsNotifier(sns, os.environ["ALERT_TOPIC_ARN"])
    return run(
        event,
        repository,
        history_repository,
        notifier,
        check_url,
        datetime.now(timezone.utc),
    )
```

- [ ] **Step 8: Run focused and full Python suites**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_aws_adapters.py tests/test_handler.py -q
.\.venv\Scripts\python.exe -m pytest -q
```

Expected: focused tests and the full Python suite pass.

- [ ] **Step 9: Commit the Python deliverable**

Run:

```powershell
git add lambda/url_monitor/aws_adapters.py lambda/url_monitor/handler.py tests/test_aws_adapters.py tests/test_handler.py
git commit -m "feat: record URL check history"
```

Expected: one commit containing only Python runtime and test changes.

---

### Task 2: Terraform History Table, Least-Privilege IAM, and Disabled Schedule

**Files:**
- Modify: `modules/url-monitor/main.tf`
- Modify: `modules/url-monitor/iam.tf`
- Modify: `modules/url-monitor/variables.tf`
- Modify: `modules/url-monitor/outputs.tf`
- Modify: `modules/url-monitor/tests/module.tftest.hcl`
- Modify: `infra/main.tf`
- Modify: `infra/monitor.auto.tfvars.json`
- Modify: `infra/outputs.tf`
- Modify: `infra/variables.tf`
- Create: `tests/test_history_terraform.py`

**Interfaces:**
- Produces: module input `schedule_enabled: bool`, default `true`.
- Produces: module output `history_table_name: string`.
- Produces: live-root input `schedule_enabled: bool`, default `false`.
- Produces: live-root output `history_table_name: string`.
- Supplies Lambda environment variable `HISTORY_TABLE_NAME`.
- Supplies Scheduler payload field `history_ttl_days = 7`.

- [ ] **Step 1: Add failing Terraform structure and safety assertions**

Extend `modules/url-monitor/tests/module.tftest.hcl`:

```hcl
  assert {
    condition     = aws_dynamodb_table.history.billing_mode == "PAY_PER_REQUEST" && aws_dynamodb_table.history.hash_key == "monitor_id" && aws_dynamodb_table.history.range_key == "checked_at"
    error_message = "History must use on-demand capacity with monitor and timestamp keys."
  }

  assert {
    condition     = aws_dynamodb_table.history.ttl[0].attribute_name == "expires_at" && aws_dynamodb_table.history.ttl[0].enabled
    error_message = "History must expire through the enabled expires_at TTL."
  }
```

Add these assertions to `wires_runtime_delivery_and_outputs`:

```hcl
  assert {
    condition     = aws_lambda_function.checker.environment[0].variables.HISTORY_TABLE_NAME == aws_dynamodb_table.history.name
    error_message = "Lambda must receive the history table name."
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.monitor.target[0].input).history_ttl_days == 7
    error_message = "Scheduler payload must retain history for seven days."
  }

  assert {
    condition     = aws_scheduler_schedule.monitor.state == "ENABLED"
    error_message = "Reusable module schedule defaults to enabled."
  }

  assert {
    condition     = length([
      for statement in data.aws_iam_policy_document.lambda.statement : statement
      if contains(statement.actions, "dynamodb:PutItem") && contains(statement.resources, aws_dynamodb_table.history.arn)
    ]) == 1
    error_message = "Lambda must receive PutItem access to the history table."
  }

  assert {
    condition     = output.history_table_name == "url-monitor-history"
    error_message = "Module must expose the history table name."
  }
```

Create `tests/test_history_terraform.py`:

```python
from pathlib import Path


def test_live_root_keeps_schedule_disabled_explicitly():
    variables = Path("infra/variables.tf").read_text(encoding="utf-8")
    root = Path("infra/main.tf").read_text(encoding="utf-8")
    values = Path("infra/monitor.auto.tfvars.json").read_text(encoding="utf-8")

    assert 'variable "schedule_enabled"' in variables
    assert "default     = false" in variables
    assert "schedule_enabled = var.schedule_enabled" in root
    assert '"schedule_enabled": false' in values


def test_history_iam_does_not_grant_runtime_read_or_scan_access():
    source = Path("modules/url-monitor/iam.tf").read_text(encoding="utf-8")
    history_block = source.split('sid = "WriteCheckHistory"', 1)[1].split("}", 1)[0]

    assert 'actions   = ["dynamodb:PutItem"]' in history_block
    assert "aws_dynamodb_table.history.arn" in history_block
    assert "dynamodb:GetItem" not in history_block
    assert "dynamodb:Query" not in history_block
    assert "dynamodb:Scan" not in history_block
```

- [ ] **Step 2: Run the focused tests and confirm the expected failures**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_history_terraform.py -q
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=modules/url-monitor test
```

Expected: pytest fails because the new Terraform inputs and IAM statement do not exist; Terraform test fails because the history table and output do not exist.

- [ ] **Step 3: Add the module history table and schedule input**

Add to `modules/url-monitor/main.tf` after the state table:

```hcl
resource "aws_dynamodb_table" "history" {
  name         = "${var.project_name}-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "monitor_id"
  range_key    = "checked_at"

  attribute {
    name = "monitor_id"
    type = "S"
  }

  attribute {
    name = "checked_at"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = var.tags
}
```

Add `HISTORY_TABLE_NAME = aws_dynamodb_table.history.name` to the Lambda environment map. Add `state = var.schedule_enabled ? "ENABLED" : "DISABLED"` to `aws_scheduler_schedule.monitor`, and add `history_ttl_days = 7` to its input object.

Add to `modules/url-monitor/variables.tf`:

```hcl
variable "schedule_enabled" {
  description = "Whether scheduled URL checks are enabled."
  type        = bool
  default     = true
}
```

- [ ] **Step 4: Restrict Lambda IAM to history writes only**

Keep the existing state-table statement unchanged. Add this separate statement to `data "aws_iam_policy_document" "lambda"` in `modules/url-monitor/iam.tf`:

```hcl
  statement {
    sid       = "WriteCheckHistory"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.history.arn]
  }
```

Do not add `GetItem`, `Query`, `Scan`, wildcard resources, or table-index ARNs.

- [ ] **Step 5: Wire module and live-root outputs with the schedule disabled**

Add to `modules/url-monitor/outputs.tf`:

```hcl
output "history_table_name" {
  description = "DynamoDB table holding seven-day check history."
  value       = aws_dynamodb_table.history.name
}
```

Add to `infra/variables.tf`:

```hcl
variable "schedule_enabled" {
  description = "Whether the production URL check schedule is enabled."
  type        = bool
  default     = false
}
```

Pass `schedule_enabled = var.schedule_enabled` in `infra/main.tf`. Add the explicit root value to `infra/monitor.auto.tfvars.json` before `monitor_targets`:

```json
{
  "schedule_enabled": false,
  "monitor_targets": {
```

Add to `infra/outputs.tf`:

```hcl
output "history_table_name" {
  description = "DynamoDB table holding seven-day check history."
  value       = module.url_monitor.history_table_name
}
```

- [ ] **Step 6: Format and run focused Terraform tests**

Run:

```powershell
.\.superpowers\tools\terraform-1.16.0\terraform.exe fmt -recursive
.\.venv\Scripts\python.exe -m pytest tests/test_history_terraform.py -q
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=modules/url-monitor init -backend=false -input=false
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=modules/url-monitor validate
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=modules/url-monitor test
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=infra init -backend=false -input=false
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=infra validate
.\.superpowers\tools\tflint-0.64.0\tflint.exe --recursive --format compact
```

Expected: formatting makes no further changes after the first command; pytest, module tests, validation, and TFLint pass without contacting or modifying AWS.

- [ ] **Step 7: Run the full local regression suite**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest -q
.\.superpowers\tools\terraform-1.16.0\terraform.exe fmt -check -recursive
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=bootstrap validate
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=bootstrap test
```

Expected: every previous Python and bootstrap test remains green.

- [ ] **Step 8: Commit the Terraform deliverable**

Run:

```powershell
git add modules/url-monitor infra tests/test_history_terraform.py
git commit -m "feat: provision URL check history"
```

Expected: one commit containing the table, IAM, environment, payload, disabled-schedule, outputs, and tests.

---

### Task 3: Operator Documentation and Final Local Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/runbook.md`

**Interfaces:**
- Consumes: root outputs `state_table_name`, `history_table_name`, and `schedule_name`.
- Documents: newest-first DynamoDB query for monitor key `demo` and the reviewed `schedule_enabled` workflow.

- [ ] **Step 1: Update the README architecture and cost description**

Replace the runtime diagram in `README.md` with:

```text
EventBridge Scheduler (5 minutes)
             |
             v
        Lambda checker ─────> DynamoDB current state
             |
             +──────────────> DynamoDB 7-day check history
             |
             +──────────────> SNS notifications
             |
             +──────────────> CloudWatch Logs and error alarm
```

Add this bullet under `What it demonstrates`:

```markdown
- Queryable per-target check history with automatic seven-day expiry
```

Replace the DynamoDB sentence in `Cost controls` with:

```markdown
DynamoDB is on-demand: the state table remains tiny, and each enabled target writes 288 small history items per day that become eligible for automatic deletion after seven days.
```

Add this paragraph to `Operate the monitor`:

```markdown
`infra/monitor.auto.tfvars.json` keeps `schedule_enabled` set to `false`. Scheduled checks remain paused until a reviewed pull request deliberately changes it to `true` and the approved Terraform deployment applies that change.
```

- [ ] **Step 2: Add exact history and schedule commands to the runbook**

Add this section after `Inspect current state` in `docs/runbook.md`:

```markdown
## Inspect recent check history

Read the history table name and query only the stable monitor partition. This returns at most 20 newest records and avoids a table scan.

    $historyTable = terraform -chdir=infra output -raw history_table_name
    aws dynamodb query --region ap-northeast-2 --table-name $historyTable --key-condition-expression "monitor_id = :monitor" --expression-attribute-values '{":monitor":{"S":"demo"}}' --no-scan-index-forward --limit 20

History expiration uses DynamoDB TTL. Items become eligible for deletion after seven days, but deletion is asynchronous.
```

Add this operating section before destroy instructions:

```markdown
## Enable or pause scheduled checks

`infra/monitor.auto.tfvars.json` is the source of truth. Change `schedule_enabled` through a pull request, require CI to pass, merge to `main`, and run the approved Terraform deployment. Use `true` to enable five-minute checks and `false` to pause them. Do not toggle the Scheduler only in the AWS console because the next Terraform deployment will restore the committed value.
```

- [ ] **Step 3: Run documentation and sensitive-value checks**

Run:

```powershell
rg -n "AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AGE-SECRET-KEY-[A-Z0-9-]+|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY" README.md docs lambda modules infra tests
git diff --check
```

Expected: the sensitive-value scan returns no matches and `git diff --check` succeeds.

- [ ] **Step 4: Run the complete final verification suite**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest -q
.\.superpowers\tools\terraform-1.16.0\terraform.exe fmt -check -recursive
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=bootstrap validate
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=bootstrap test
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=modules/url-monitor validate
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=modules/url-monitor test
.\.superpowers\tools\terraform-1.16.0\terraform.exe -chdir=infra validate
.\.superpowers\tools\tflint-0.64.0\tflint.exe --recursive --format compact
git status --short
```

Expected: all Python and Terraform tests, formatting, validation, and lint pass; only the intended README and runbook changes remain uncommitted.

- [ ] **Step 5: Commit the documentation**

Run:

```powershell
git add README.md docs/runbook.md
git commit -m "docs: add check history operations"
git status --short
```

Expected: the worktree is clean, with three implementation commits after the design commit. Do not push, merge, run a live Terraform plan, deploy, or enable the Scheduler.
