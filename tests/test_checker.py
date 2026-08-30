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
