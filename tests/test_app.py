import os
import socket
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest

os.environ["DATABASE_URL"] = "sqlite:///./test_uptime.db"
os.environ["SESSION_SECRET"] = "test-secret"

from fastapi.testclient import TestClient

from app.checker import ensure_public_host, normalize_url
from app.database import Base, SessionLocal, engine
from app.main import app
from app.models import Check, Monitor


TEST_DB = Path("test_uptime.db")


def setup_function():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)


def teardown_module():
    Base.metadata.drop_all(bind=engine)
    engine.dispose()
    TEST_DB.unlink(missing_ok=True)


def csrf_from(response) -> str:
    marker = 'name="csrf" value="'
    return response.text.split(marker, 1)[1].split('"', 1)[0]


def register(client: TestClient):
    page = client.get("/register")
    return client.post(
        "/register",
        data={"email": "user@example.com", "password": "password123", "csrf": csrf_from(page)},
        follow_redirects=False,
    )


def test_health_endpoint():
    with TestClient(app) as client:
        response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_register_and_create_monitor():
    with TestClient(app) as client:
        response = register(client)
        assert response.status_code == 303

        page = client.get("/monitors/new")
        response = client.post(
            "/monitors",
            data={
                "name": "Example",
                "url": "https://example.com",
                "interval_seconds": "60",
                "csrf": csrf_from(page),
            },
            follow_redirects=False,
        )
        assert response.status_code == 303

        api_response = client.get("/api/monitors")
        assert api_response.status_code == 200
        assert api_response.json()[0]["name"] == "Example"


def test_user_cannot_see_another_users_monitor():
    with TestClient(app) as first_client:
        register(first_client)
        page = first_client.get("/monitors/new")
        first_client.post(
            "/monitors",
            data={
                "name": "Private",
                "url": "https://example.com",
                "interval_seconds": "60",
                "csrf": csrf_from(page),
            },
        )

    with TestClient(app) as second_client:
        page = second_client.get("/register")
        second_client.post(
            "/register",
            data={"email": "other@example.com", "password": "password123", "csrf": csrf_from(page)},
        )
        response = second_client.get("/monitors/1")
        assert response.status_code == 404


def test_login_rejects_wrong_password():
    with TestClient(app) as client:
        register(client)
        page = client.get("/login")
        response = client.post(
            "/login",
            data={"email": "user@example.com", "password": "wrong-password", "csrf": csrf_from(page)},
        )
        assert response.status_code == 400
        assert "Incorrect email or password." in response.text


def test_url_validation_blocks_private_network(monkeypatch):
    def private_dns_result(*_):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 0))]

    monkeypatch.setattr(socket, "getaddrinfo", private_dns_result)
    with pytest.raises(ValueError, match="Local and private network"):
        ensure_public_host("http://internal.example")


def test_url_requires_http_scheme():
    with pytest.raises(ValueError, match="http"):
        normalize_url("example.com")


def create_monitor(client: TestClient):
    page = client.get("/monitors/new")
    response = client.post(
        "/monitors",
        data={"name": "Example", "url": "https://example.com", "interval_seconds": 60,
              "csrf": csrf_from(page)},
        follow_redirects=False,
    )
    assert response.status_code == 303
    return response.headers["location"]


def test_empty_history_and_check_api_access():
    with TestClient(app) as client:
        response = client.get("/api/monitors/1/checks", follow_redirects=False)
        assert response.status_code == 303
        assert response.headers["location"] == "/login"
        register(client)
        location = create_monitor(client)
        page = client.get(location)
        assert page.status_code == 200
        assert '<html lang="en">' in page.text
        assert "No checks yet." in page.text
        assert "Response time" in page.text
        response = client.get("/api/monitors/1/checks")
        assert response.headers["cache-control"] == "no-store"
        assert response.json()["checks"] == []
        assert response.json()["uptime"] is None
        assert response.json()["monitor"]["is_available"] is None

    with TestClient(app) as other:
        page = other.get("/register")
        other.post("/register", data={"email": "other@example.com", "password": "password123",
                                      "csrf": csrf_from(page)})
        assert other.get("/api/monitors/1/checks").status_code == 404
        assert other.get("/api/monitors/999/checks").status_code == 404


def test_chart_keeps_latest_50_and_all_time_uptime():
    with TestClient(app) as client:
        register(client)
        location = create_monitor(client)
        when = datetime.now(UTC)
        with SessionLocal() as db:
            # Tied timestamps test the stable ID ordering used by live updates.
            db.add_all([
                Check(monitor_id=1, checked_at=when, is_available=i % 5 != 0,
                      status_code=200 if i % 5 else None,
                      response_time_ms=i * 10 if i % 5 else None,
                      error_message=None if i % 5 else "Request timed out.")
                for i in range(55)
            ])
            db.commit()
        snapshot = client.get("/api/monitors/1/checks").json()
        assert snapshot["total_checks"] == 55
        assert snapshot["uptime"] == 80.0
        assert [check["id"] for check in snapshot["checks"]] == list(range(55, 5, -1))
        assert snapshot["chart_max_ms"] == 600
        assert all(check["checked_at"].endswith("+00:00") for check in snapshot["checks"])
        failed = next(check for check in snapshot["checks"] if not check["is_available"])
        assert failed["response_time_ms"] is None
        assert failed["chart_height"] == 0
        page = client.get(location)
        assert page.text.count('class="check-bar ') == 50
        assert "80.0%" in page.text
        assert "Request timed out." in page.text


def test_manual_and_background_checks_reach_chart_history(monkeypatch):
    from app import checker, worker

    original_client = httpx.Client
    monkeypatch.setattr(checker, "ensure_public_host", lambda _: None)
    monkeypatch.setattr(checker.httpx, "Client", lambda **kwargs: original_client(
        transport=httpx.MockTransport(lambda _: httpx.Response(200)), **kwargs))
    with TestClient(app) as client:
        register(client)
        location = create_monitor(client)
        assert client.post(f"{location}/check", data={"csrf": "wrong"}).status_code == 403
        response = client.post(f"{location}/check", data={"csrf": csrf_from(client.get(location))})
        assert response.status_code == 200
        snapshot = client.get("/api/monitors/1/checks").json()
        assert snapshot["total_checks"] == 1
        assert snapshot["monitor"]["is_available"] is True
        assert snapshot["checks"][0]["status_code"] == 200
        with SessionLocal() as db:
            monitor = db.get(Monitor, 1)
            monitor.next_check_at = datetime.now(UTC) - timedelta(seconds=1)
            db.commit()
        assert worker.run_due_checks() == 1
        assert client.get("/api/monitors/1/checks").json()["total_checks"] == 2


def test_failed_check_returns_no_latency_instead_of_zero(monkeypatch):
    from app import checker

    def timeout(_):
        raise httpx.ReadTimeout("Request timed out.")

    original_client = httpx.Client
    monkeypatch.setattr(checker, "ensure_public_host", lambda _: None)
    monkeypatch.setattr(checker.httpx, "Client", lambda **kwargs: original_client(
        transport=httpx.MockTransport(timeout), **kwargs))
    with TestClient(app) as client:
        register(client)
        location = create_monitor(client)
        response = client.post(f"{location}/check", data={"csrf": csrf_from(client.get(location))})
        assert response.status_code == 200
        snapshot = client.get("/api/monitors/1/checks").json()
        assert snapshot["monitor"]["is_available"] is False
        assert snapshot["uptime"] == 0.0
        assert snapshot["checks"][0]["response_time_ms"] is None
        assert snapshot["checks"][0]["error_message"] == "Request timed out."
        assert "No response" in response.text
        assert "DOWN · No response" in client.get("/dashboard").text
