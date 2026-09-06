import ipaddress
import socket
import time
from datetime import UTC, datetime, timedelta
from urllib.parse import urlparse

import httpx
from sqlalchemy.orm import Session

from .models import Check, Monitor


def normalize_url(value: str) -> str:
    value = value.strip()
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("URL должен начинаться с http:// или https://")
    if parsed.username or parsed.password:
        raise ValueError("URL с логином или паролем не поддерживается")
    return value


def ensure_public_host(url: str) -> None:
    """Block requests to local networks to reduce SSRF risk."""
    hostname = urlparse(url).hostname
    if not hostname:
        raise ValueError("Некорректный адрес")

    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(hostname, None)}
    except socket.gaierror as exc:
        raise ValueError("Не удалось найти адрес сайта") from exc

    if not addresses:
        raise ValueError("Не удалось найти адрес сайта")

    for address in addresses:
        if not ipaddress.ip_address(address).is_global:
            raise ValueError("Локальные и внутренние адреса запрещены")


def run_monitor_check(db: Session, monitor: Monitor) -> Check:
    checked_at = datetime.now(UTC)
    status_code = None
    response_time_ms = None
    error_message = None
    is_available = False

    try:
        ensure_public_host(monitor.url)
        started = time.perf_counter()
        with httpx.Client(timeout=10, follow_redirects=False) as client:
            response = client.get(
                monitor.url,
                headers={"User-Agent": "UptimeMonitor/1.0"},
            )
        response_time_ms = round((time.perf_counter() - started) * 1000, 2)
        status_code = response.status_code
        is_available = status_code < 500
    except (httpx.HTTPError, ValueError) as exc:
        error_message = str(exc)[:500]

    check = Check(
        monitor=monitor,
        status_code=status_code,
        response_time_ms=response_time_ms,
        is_available=is_available,
        error_message=error_message,
        checked_at=checked_at,
    )
    monitor.last_available = is_available
    monitor.last_status_code = status_code
    monitor.last_checked_at = checked_at
    monitor.next_check_at = checked_at + timedelta(seconds=monitor.interval_seconds)
    db.add(check)
    db.commit()
    db.refresh(check)
    return check

