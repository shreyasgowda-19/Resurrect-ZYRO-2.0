from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from app import firebase_service
from app.inventory.engine import calculate_inventory
from app.inventory.events import EtaEvent, apply_event
from app.inventory.models import InventoryInput
from app.inventory.recovery import actions, hypothetical_facts
from app.main import app

HEADERS = {"Authorization": "Bearer mocked-token"}
REQUEST = {"order_id": "ORD-1042", "expected_version": 2}


@pytest.fixture
def delayed(inventory_backend):
    event = EtaEvent(
        event_id="delay", event_type="supplier_eta_update", expected_version=1,
        payload={"lot_id": "LOT-01", "new_eta": "2026-12-08"},
    )
    inventory_backend.state, _ = apply_event(inventory_backend.state, event, datetime(2026, 12, 1, tzinfo=UTC))
    return inventory_backend


@pytest.fixture
def client(delayed, monkeypatch):
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "planner", "role": "planner"})
    with TestClient(app) as test_client:
        yield test_client


def recommend(client):
    response = client.post("/recommendations", headers=HEADERS, json=REQUEST)
    assert response.status_code == 200
    return response.json()


def simulate(client, recommendation_id):
    response = client.post("/simulate", headers=HEADERS, json={**REQUEST, "recommendation_id": recommendation_id})
    assert response.status_code == 200
    return response.json()


def test_golden_recommendations_and_consistent_read_only_simulation(client, delayed, monkeypatch):
    def unexpected_write(*args, **kwargs):
        pytest.fail("Read-only endpoints attempted to submit an event")

    monkeypatch.setattr(delayed, "submit", unexpected_write)
    original = delayed.state.model_dump_json()
    before = recommend(client)
    assert before == recommend(client)
    assert set(before) == {"order_id", "version", "data_mode", "recommendations"}
    assert (before["order_id"], before["version"], before["data_mode"]) == ("ORD-1042", 2, "demo")
    recommendations = before["recommendations"]
    assert [item["action_type"] for item in recommendations] == ["expedite_existing_lot", "alternate_supplier_po"]
    assert len({item["recommendation_id"] for item in recommendations}) == 2

    for item in recommendations:
        assert item["quantity"] == 400
        assert item["proposed_eta"] == "2026-12-05"
        assert item["estimated_incremental_cost"] is None
        assert item["currency"] is None
        assert item["evidence"]
        assert any("Synthetic" in assumption for assumption in item["assumptions"])
        result = simulate(client, item["recommendation_id"])
        assert result == simulate(client, item["recommendation_id"])
        assert set(result) == {
            "order_id", "recommendation_id", "version", "hypothetical", "before", "after",
            "affected_orders", "estimated_incremental_cost", "currency", "assumptions", "warnings",
        }
        assert result["hypothetical"] is True
        assert result["before"] == {
            "projected_ship_date": "2026-12-10", "projected_delivery_date": "2026-12-11",
            "slack_days": -1, "risk": "critical",
        }
        assert result["after"] == {
            "projected_ship_date": "2026-12-07", "projected_delivery_date": "2026-12-08",
            "slack_days": 2, "risk": "on_track",
        }
        assert result["affected_orders"] == []
        assert result["estimated_incremental_cost"] is None and result["currency"] is None

    assert recommendations[0]["lot_id"] == "LOT-01"
    assert recommendations[1]["lot_id"] is None
    assert recommendations[1]["supplier_id"] == "SUP-02"
    assert delayed.state.model_dump_json() == original
    assert delayed.records == {}


def test_actions_preserve_physical_stock_and_expedite_quantity(delayed):
    facts = delayed.state.facts
    baseline = calculate_inventory(facts)
    order = next(item for item in baseline.orders if item.order_id == "ORD-1042")
    expedite, alternate = actions(baseline, order)
    faster = hypothetical_facts(facts, expedite, "expedite")
    augmented = hypothetical_facts(facts, alternate, "alternate")
    assert faster.materials == augmented.materials == facts.materials
    assert len(faster.incoming_lots) == len(facts.incoming_lots)
    copper = next(item for item in faster.incoming_lots if item.lot_id == "LOT-01")
    assert (copper.quantity, str(copper.expected_arrival)) == (400, "2026-12-05")
    assert augmented.incoming_lots[:-1] == facts.incoming_lots
    assert augmented.incoming_lots[-1].quantity == 400
    assert augmented.incoming_lots[-1].status == "confirmed"
    assert str(augmented.incoming_lots[-1].expected_arrival) == "2026-12-05"
    assert facts.incoming_lots[0].expected_arrival != copper.expected_arrival


def test_collateral_changes_include_only_affected_other_orders(client, delayed):
    original = delayed.state.facts.model_dump()
    target = next(order for order in original["orders"] if order["order_id"] == "ORD-1042")
    original["orders"] = (*original["orders"], {
        **target,
        "order_id": "ORD-OTHER",
        "priority": "low",
        "requirements": ({"material_id": "MAT-COPPER", "quantity": 400},),
    })
    delayed.state = delayed.state.model_copy(update={"facts": InventoryInput.model_validate(original)})

    alternate = next(item for item in recommend(client)["recommendations"] if item["action_type"] == "alternate_supplier_po")
    changes = simulate(client, alternate["recommendation_id"])["affected_orders"]
    assert len(changes) == 1
    assert changes[0]["order_id"] == "ORD-OTHER"
    assert changes[0]["before"]["projected_delivery_date"] is None
    assert changes[0]["after"]["projected_delivery_date"] == "2026-12-11"


def test_no_feasible_candidates_and_no_invented_alternate(client):
    for order_id in ("ORD-1046", "ORD-1047"):
        response = client.post("/recommendations", headers=HEADERS, json={**REQUEST, "order_id": order_id})
        assert response.status_code == 200
        assert response.json()["recommendations"] == []


def test_ids_are_bound_to_version_and_reject_tampering(client, delayed):
    rec_id = recommend(client)["recommendations"][0]["recommendation_id"]
    for unknown in (rec_id + "x", "unknown"):
        response = client.post("/simulate", headers=HEADERS, json={**REQUEST, "recommendation_id": unknown})
        assert response.status_code == 404

    delayed.state = delayed.state.model_copy(update={"version": 3})
    response = client.post("/recommendations", headers=HEADERS, json={**REQUEST, "expected_version": 3})
    assert response.status_code == 200
    assert response.json()["recommendations"][0]["recommendation_id"] != rec_id
    response = client.post("/simulate", headers=HEADERS, json={
        **REQUEST, "expected_version": 3, "recommendation_id": rec_id,
    })
    assert response.status_code == 404


@pytest.mark.parametrize("path", ["/recommendations", "/simulate"])
def test_error_contract(client, delayed, monkeypatch, path):
    body = REQUEST if path == "/recommendations" else {**REQUEST, "recommendation_id": "unknown"}
    assert client.post(path, json=body).status_code == 401
    stale = client.post(path, headers=HEADERS, json={**body, "expected_version": 1})
    assert stale.status_code == 409
    assert stale.json()["detail"]["code"] == "STALE_VERSION"
    unknown = client.post(path, headers=HEADERS, json={**body, "order_id": "missing"})
    assert unknown.status_code == 404
    invalid = client.post(path, headers=HEADERS, json={**body, "expected_version": True})
    assert invalid.status_code == 422
    assert invalid.json()["detail"]["code"] == "INVALID_REQUEST"

    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "other", "role": "admin"})
    assert client.post(path, headers=HEADERS, json=body).status_code == 403
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {"uid": "approver", "role": "approver"})
    assert client.post(path, headers=HEADERS, json=body).status_code == (200 if path == "/recommendations" else 404)
    delayed.fail = True
    failed = client.post(path, headers=HEADERS, json=body)
    assert failed.status_code == 503
    assert failed.json()["detail"]["code"] == "SERVICE_UNAVAILABLE"


@pytest.mark.parametrize(("crd", "risk"), [("2026-12-12", "at_risk"), ("2026-11-30", "delayed")])
def test_at_risk_and_delayed_orders_can_receive_recommendations(client, delayed, crd, risk):
    facts = delayed.state.facts.model_dump()
    target = next(order for order in facts["orders"] if order["order_id"] == "ORD-1042")
    target["crd"] = crd
    delayed.state = delayed.state.model_copy(update={"facts": InventoryInput.model_validate(facts)})
    candidate = recommend(client)["recommendations"][0]
    result = simulate(client, candidate["recommendation_id"])
    assert result["before"]["risk"] == risk
    assert result["after"]["projected_delivery_date"] == "2026-12-08"
    if risk == "delayed":
        assert result["after"]["risk"] == "delayed"
        assert any("remains delayed" in warning for warning in result["warnings"])
