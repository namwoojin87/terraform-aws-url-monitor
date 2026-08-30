import socket
import ssl
from time import perf_counter
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from url_monitor.domain import CheckResult, Target


def _failure(category: str, message: str, started: float, status: int | None = None) -> CheckResult:
    return CheckResult(False, status, round((perf_counter() - started) * 1000), category, message)


def check_url(target: Target, opener=urlopen) -> CheckResult:
    started = perf_counter()
    request = Request(target.url, headers={"User-Agent": "terraform-url-monitor/1.0"})
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
