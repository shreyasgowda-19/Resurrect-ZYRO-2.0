import pytest
from fastapi.testclient import TestClient

from app import firebase_service
from app.main import app

HEADERS = {"Authorization": "Bearer mocked-token"}


def event(kind="supplier_eta_update", payload=None, *, event_id="event-1", version=1):
    if payload is None:
        payload = {"lot_id": "LOT-01", "new_eta": "2026-12-08"}
    return {"event_id": event_id, "event_type": kind, "expected_version": version, "payload": payload}


@pytest.fixture
def client(inventory_backend, monkeypatch):
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "planner-1", "role": "planner"})
    with TestClient(app) as test_client:
        yield test_client


def current(client):
    response = client.get("/state", headers=HEADERS)
    assert response.status_code == 200
    return response.json()


def copper(data):
    return next(material for material in data["materials"] if material["material_id"] == "MAT-COPPER")


def copper_order(data):
    return next(order for order in data["orders"] if order["order_id"] == "ORD-1042")


def test_golden_eta_alert_and_idempotent_replay(client):
    initial = current(client)
    assert (initial["version"], copper_order(initial)["risk"]) == (1, "on_track")
    body = event()
    first = client.post("/events", json=body, headers=HEADERS)
    assert first.status_code == 200
    assert first.json() == {"event_id": "event-1", "status": "applied", "version": 2}
    state = current(client)
    order = copper_order(state)
    assert (order["projected_ship_date"], order["projected_delivery_date"], order["slack_days"], order["risk"]) == (
        "2026-12-10", "2026-12-11", -1, "critical"
    )
    assert state["recent_events"][0]["event_id"] == "event-1"
    assert state["recent_events"][0]["version"] == 2
    alert = state["alerts"][0]
    assert (alert["order_id"], alert["previous_risk"], alert["new_risk"], alert["version"]) == (
        "ORD-1042", "on_track", "critical", 2
    )
    assert "2026-12-11" in alert["message"]
    replay = client.post("/events", json=body, headers=HEADERS)
    assert replay.json() == {"event_id": "event-1", "status": "duplicate", "version": 2}
    assert current(client) == state


def test_receipt_moves_stock_without_double_counting(client):
    for version, quantity in [(1, 150), (2, 250)]:
        body = event("material_receipt", {"lot_id": "LOT-01", "quantity": quantity}, event_id=f"receipt-{version}", version=version)
        assert client.post("/events", json=body, headers=HEADERS).status_code == 200
        state = current(client)
        material = copper(state)
        lot = next(lot for lot in state["supply_lots"] if lot["lot_id"] == "LOT-01")
        assert material["on_hand"] + material["incoming"] == 1000
        assert material["incoming"] == lot["remaining_quantity"]
        assert material["allocated"] == 1000
    assert (lot["status"], lot["remaining_quantity"]) == ("received", 0)
    assert material["on_hand"] == 1000


def test_signed_stock_adjustment(client):
    for version, delta, expected in [(1, 5, 605), (2, -10, 595)]:
        body = event("stock_adjustment", {"material_id": "MAT-COPPER", "quantity_delta": delta},
                     event_id=f"stock-{version}", version=version)
        assert client.post("/events", json=body, headers=HEADERS).status_code == 200
        assert copper(current(client))["on_hand"] == expected


def test_order_change_updates_crd_and_requirement(client):
    body = event("order_change", {
        "order_id": "ORD-1042", "new_crd": "2026-12-12", "material_id": "MAT-COPPER", "new_required_quantity": 0,
    })
    assert client.post("/events", json=body, headers=HEADERS).status_code == 200
    state = current(client)
    order = copper_order(state)
    assert (order["crd"], order["material_ready_date"]) == ("2026-12-12", "2026-12-01")
    assert copper(state)["allocated"] == 0
    assert {"order_id": "ORD-1042", "material_id": "MAT-COPPER", "required_quantity": 0} in state["order_requirements"]


@pytest.mark.parametrize(("kind", "payload", "status", "code"), [
    ("supplier_eta_update", {"lot_id": "UNKNOWN", "new_eta": "2026-12-08"}, 404, "NOT_FOUND"),
    ("supplier_eta_update", {"lot_id": "LOT-01", "new_eta": "2026-11-30"}, 422, "INVALID_OPERATION"),
    ("supplier_eta_update", {"lot_id": "LOT-05", "new_eta": "2026-12-08"}, 422, "INVALID_OPERATION"),
    ("supplier_eta_update", {"lot_id": "LOT-01", "new_eta": "12/08/2026"}, 422, "INVALID_EVENT"),
    ("material_receipt", {"lot_id": "LOT-01", "quantity": 401}, 422, "INVALID_OPERATION"),
    ("material_receipt", {"lot_id": "LOT-06", "quantity": 1}, 422, "INVALID_OPERATION"),
    ("material_receipt", {"lot_id": "LOT-01", "quantity": True}, 422, "INVALID_EVENT"),
    ("stock_adjustment", {"material_id": "MAT-COPPER", "quantity_delta": -601}, 422, "INVALID_OPERATION"),
    ("stock_adjustment", {"material_id": "MAT-COPPER", "quantity_delta": 0}, 422, "INVALID_EVENT"),
    ("stock_adjustment", {"material_id": "UNKNOWN", "quantity_delta": 1}, 404, "NOT_FOUND"),
    ("order_change", {"order_id": "UNKNOWN", "new_crd": "2026-12-15"}, 404, "NOT_FOUND"),
    ("order_change", {"order_id": "ORD-1042", "material_id": "MAT-PCB", "new_required_quantity": 3}, 404, "NOT_FOUND"),
    ("order_change", {"order_id": "ORD-1042", "material_id": "MAT-PCB"}, 422, "INVALID_EVENT"),
    ("order_change", {"order_id": "ORD-1042"}, 422, "INVALID_EVENT"),
    ("unknown", {}, 422, "INVALID_EVENT"),
])
def test_failed_events_leave_state_unchanged(client, kind, payload, status, code):
    initial = current(client)
    response = client.post("/events", json=event(kind, payload), headers=HEADERS)
    assert response.status_code == status
    assert response.json()["detail"]["code"] == code
    assert current(client) == initial


def test_stale_and_conflicting_events(client, monkeypatch):
    assert client.post("/events", json=event(), headers=HEADERS).status_code == 200
    new_id = client.post("/events", json=event(event_id="event-2"), headers=HEADERS)
    assert new_id.status_code == 409
    assert new_id.json()["detail"] == {
        "code": "STALE_VERSION", "message": "Refresh the dashboard before submitting another event.",
    }
    changed = client.post("/events", json=event(version=2), headers=HEADERS)
    assert changed.status_code == 409
    assert changed.json()["detail"]["code"] == "EVENT_ID_CONFLICT"
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "planner-2", "role": "planner"})
    other = client.post("/events", json=event(), headers=HEADERS)
    assert other.status_code == 409
    assert other.json()["detail"]["code"] == "EVENT_ID_CONFLICT"
    assert current(client)["version"] == 2


def test_approver_can_read_but_cannot_submit(client, monkeypatch):
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "approver", "role": "approver"})
    assert current(client)["version"] == 1
    response = client.post("/events", json=event(), headers=HEADERS)
    assert response.status_code == 403
    assert response.json()["detail"]["code"] == "FORBIDDEN"


def test_event_requires_authentication(client):
    response = client.post("/events", json=event())
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json()["detail"]["code"] == "UNAUTHENTICATED"


def test_commit_failure_does_not_partially_update(client, inventory_backend):
    initial = current(client)
    inventory_backend.fail = True
    response = client.post("/events", json=event(), headers=HEADERS)
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "SERVICE_UNAVAILABLE"
    assert client.get("/state", headers=HEADERS).status_code == 503
    inventory_backend.fail = False
    assert current(client) == initial
    assert client.post("/events", json=event(), headers=HEADERS).json()["status"] == "applied"


def test_events_and_alerts_are_limited_and_newest_first(client):
    for version in range(1, 43):
        eta = "2026-12-08" if version % 2 else "2026-12-05"
        body = event(payload={"lot_id": "LOT-01", "new_eta": eta}, event_id=f"event-{version}", version=version)
        assert client.post("/events", json=body, headers=HEADERS).status_code == 200
    state = current(client)
    assert [entry["version"] for entry in state["recent_events"]] == list(range(43, 23, -1))
    assert [entry["version"] for entry in state["alerts"]] == list(range(42, 2, -2))
    replay = client.post("/events", json=event(), headers=HEADERS)
    assert replay.json() == {"event_id": "event-1", "status": "duplicate", "version": 2}
