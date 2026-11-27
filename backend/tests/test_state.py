import pytest
from fastapi.testclient import TestClient

from app import firebase_service
from app.main import app

AUTHORIZATION = {"Authorization": "Bearer mocked-token"}


@pytest.fixture
def client(inventory_backend):
    with TestClient(app) as test_client:
        yield test_client


@pytest.mark.parametrize("role", ["planner", "approver"])
def test_state_matches_contract_and_is_deterministic(client, monkeypatch, role):
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "user", "role": role})
    response = client.get("/state", headers=AUTHORIZATION)
    assert response.status_code == 200
    payload = response.json()
    assert payload == client.get("/state", headers=AUTHORIZATION).json()
    assert set(payload) == {"version", "as_of_date", "data_mode", "materials", "orders", "supply_lots", "order_requirements", "recent_events", "alerts"}
    assert (payload["version"], payload["as_of_date"], payload["data_mode"]) == (1, "2026-12-01", "demo")
    assert len(payload["materials"]) == 6
    assert len(payload["orders"]) == 10

    copper = next(item for item in payload["materials"] if item["name"] == "Copper")
    assert copper == {
        "material_id": "MAT-COPPER", "name": "Copper", "unit": "busbar blanks",
        "on_hand": 600, "incoming": 400, "allocated": 1000, "net_available": 0,
    }
    orders = {order["order_id"]: order for order in payload["orders"]}
    assert orders["ORD-1042"] == {
        "order_id": "ORD-1042", "customer": "Demo Harbor Switchgear", "priority": "high",
        "crd": "2026-12-10", "material_ready_date": "2026-12-05",
        "projected_ship_date": "2026-12-07", "projected_delivery_date": "2026-12-08",
        "slack_days": 2, "risk": "on_track", "shortages": [],
    }
    shortage_order = orders["ORD-1046"]
    for field in ("material_ready_date", "projected_ship_date", "projected_delivery_date", "slack_days"):
        assert shortage_order[field] is None
    assert shortage_order["risk"] == "critical"
    assert shortage_order["shortages"] == [
        {"material_id": "MAT-RESIN", "required": 125, "available": 95, "shortage": 30}
    ]


def test_state_requires_token(client):
    response = client.get("/state")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_state_rejects_unauthorized_role(client, monkeypatch):
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "user", "role": "admin"})
    assert client.get("/state", headers=AUTHORIZATION).status_code == 403


@pytest.mark.parametrize(("error", "status"), [
    (firebase_service.InvalidToken, 401),
    (firebase_service.FirebaseUnavailable, 503),
])
def test_state_auth_failure(client, monkeypatch, error, status):
    def verify(token):
        raise error("Mocked Firebase failure")

    monkeypatch.setattr(firebase_service, "verify_token", verify)
    assert client.get("/state", headers=AUTHORIZATION).status_code == status
