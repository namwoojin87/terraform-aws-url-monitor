import logging
import os
from datetime import datetime, timedelta, timezone

import boto3

from url_monitor.aws_adapters import DynamoHistoryRepository, DynamoStateRepository, SnsNotifier
from url_monitor.checker import check_url
from url_monitor.domain import Target, decide_state

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)


def run(event, repository, history_repository, notifier, checker, now):
    checked = 0
    errors = []
    threshold = int(event["failure_threshold"])
    expires_at = int((now + timedelta(days=int(event["state_ttl_days"]))).timestamp())
    history_expires_at = int(
        (now + timedelta(days=int(event["history_ttl_days"]))).timestamp()
    )
    checked_at = now.isoformat()

    for name, config in event["targets"].items():
        try:
            target = Target(
                name=name,
                url=config["url"],
                expected_statuses=frozenset(config["expected_statuses"]),
                timeout_seconds=int(config["timeout_seconds"]),
            )
            current = repository.get(name)
            result = checker(target)
            decision = decide_state(current, result, threshold, checked_at, expires_at)
            if decision.notification:
                notifier.publish(decision.notification, target, result, checked_at)
            repository.put(name, decision.state)
            history_repository.put(name, checked_at, result, decision.state, history_expires_at)
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
