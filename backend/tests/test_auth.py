import pytest
from fastapi.testclient import TestClient

from app import firebase_service
from app.main import app


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def test_missing_token(client):
    response = client.get("/auth/me")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


@pytest.mark.parametrize("role, expected_status", [("planner", 200), ("approver", 200), ("admin", 403), (None, 403)])
def test_role_from_verified_token(client, monkeypatch, role, expected_status):
    claims = {"uid": "test-uid", "email": "test@example.com", "role": role}
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: claims)
    response = client.get("/auth/me", headers={"Authorization": "Bearer mocked-token"})
    assert response.status_code == expected_status
    if expected_status == 200:
        assert response.json() == claims


@pytest.mark.parametrize("error_type, expected_status", [
    (firebase_service.InvalidToken, 401),
    (firebase_service.FirebaseUnavailable, 503),
])
def test_auth_failure(client, monkeypatch, error_type, expected_status):
    def verify(token):
        raise error_type("Mocked failure")

    monkeypatch.setattr(firebase_service, "verify_token", verify)
    response = client.get("/auth/me", headers={"Authorization": "Bearer mocked-token"})
    assert response.status_code == expected_status


def test_flutter_can_send_authorization_header(client):
    origin = "http://localhost:3000"
    response = client.options("/auth/me", headers={
        "Origin": origin,
        "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "Authorization",
    })
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == origin
    assert "authorization" in response.headers["access-control-allow-headers"].lower()
