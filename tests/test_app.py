import os
import socket
from pathlib import Path

import pytest

os.environ["DATABASE_URL"] = "sqlite:///./test_uptime.db"
os.environ["SESSION_SECRET"] = "test-secret"

from fastapi.testclient import TestClient

from app.checker import ensure_public_host, normalize_url
from app.database import Base, SessionLocal, engine
from app.main import app


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
        assert "Неверный email или пароль" in response.text


def test_url_validation_blocks_private_network(monkeypatch):
    def private_dns_result(*_):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 0))]

    monkeypatch.setattr(socket, "getaddrinfo", private_dns_result)
    with pytest.raises(ValueError, match="Локальные и внутренние"):
        ensure_public_host("http://internal.example")


def test_url_requires_http_scheme():
    with pytest.raises(ValueError, match="http"):
        normalize_url("example.com")
