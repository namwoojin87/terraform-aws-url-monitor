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
