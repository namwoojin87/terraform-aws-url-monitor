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
