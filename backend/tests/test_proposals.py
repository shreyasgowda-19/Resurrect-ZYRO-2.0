from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from app import firebase_service
from app.auth import AuthenticatedUser
from app.inventory.demo import demo_inventory
from app.inventory.events import DemoState, EtaEvent, EventError, apply_event
from app.inventory.proposal_models import DecisionRequest
from app.inventory.proposal_store import FirestoreProposalStore, proposal_store
from app.inventory.proposals import stable_id
from app.inventory.recovery import evaluate_candidates
from app.inventory.recovery_models import SimulationRequest
from app.inventory.store import inventory_store
from app.main import app

from scripts.evaluation_firestore import ROOT, Document, MemoryFirestore
HEADERS = {
    role: {"Authorization": f"Bearer {role}"}
    for role in ("planner", "approver", "self", "second-planner")
}
NOW = datetime(2026, 12, 1, tzinfo=UTC)
APPROVER = AuthenticatedUser(uid="approver", email=None, role="approver")


@pytest.fixture
def workflow(monkeypatch):
    import app.inventory.proposal_store as module

    initial = DemoState(version=1, facts=demo_inventory())
    event = EtaEvent(
        event_id="delay", event_type="supplier_eta_update", expected_version=1,
        payload={"lot_id": "LOT-01", "new_eta": "2026-12-08"},
    )
    state, _ = apply_event(initial, event, NOW)
    db = MemoryFirestore(state)
    store = FirestoreProposalStore()
    monkeypatch.setattr(module, "transactional", db.transactional)
    monkeypatch.setattr(store, "_references", lambda: (db, Document(db, ROOT)))
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {
        "uid": "planner" if token == "self" else token,
        "role": "approver" if token in ("approver", "self") else "planner",
    })
    monkeypatch.setitem(app.dependency_overrides, proposal_store, lambda: store)
    monkeypatch.setitem(app.dependency_overrides, inventory_store, lambda: store)
    with TestClient(app) as client:
        yield client, store, db


def request_for(store, action_type="alternate_supplier_po"):
    state = store.read()
    candidate = next(
        item for item in evaluate_candidates(state, "ORD-1042")
        if item.recommendation.action_type == action_type
    )
    return SimulationRequest(
        order_id="ORD-1042", expected_version=state.version,
        recommendation_id=candidate.recommendation.recommendation_id,
    ).model_dump(mode="json")


def submit(client, store, action_type="alternate_supplier_po"):
    response = client.post("/proposals", headers=HEADERS["planner"], json=request_for(store, action_type))
    assert response.status_code == 200
    assert response.json()["status"] == "created"
    return response.json()["proposal"]


def decision(decision_id="decision-1", **changes):
    return {
        "decision_id": decision_id,
        "decision": "approve",
        "expected_version": 2,
        "reason": "Reviewed the evidence.",
        "acknowledge_demo_assumptions": True,
        **changes,
    }


def decide(client, proposal, body=None, role="approver"):
    path = f"/proposals/{proposal['proposal_id']}/decision"
    return client.post(path, headers=HEADERS[role], json=body if body is not None else decision())


def test_submission_is_idempotent_and_does_not_change_inventory(workflow):
    client, store, _ = workflow
    before = store.read()
    request = request_for(store)
    proposal = submit(client, store)
    assert proposal["status"] == "pending" and proposal["snapshot_version"] == 2
    assert proposal["recommendation"]["recommendation_id"] == request["recommendation_id"]
    assert proposal["simulation"]["after"]["projected_delivery_date"] == "2026-12-08"
    duplicate = client.post("/proposals", headers=HEADERS["planner"], json=request)
    assert duplicate.json() == {"status": "duplicate", "version": 2, "proposal": proposal}
    conflict = client.post("/proposals", headers=HEADERS["second-planner"], json=request)
    assert conflict.status_code == 409
    assert store.read() == before
    listed = client.get("/proposals", headers=HEADERS["approver"]).json()
    assert listed["proposals"] == [proposal]
    assert listed["purchase_orders"] == []
    audit = listed["audit_logs"][0]
    assert (audit["action"], audit["actor_uid"], audit["actor_role"], audit["version"]) == (
        "proposal_submitted", "planner", "planner", 2,
    )


def test_role_separation_and_self_approval(workflow):
    client, store, _ = workflow
    request = request_for(store)
    assert client.post("/proposals", json=request).status_code == 401
    assert client.post("/proposals", headers=HEADERS["approver"], json=request).status_code == 403
    assert client.get("/proposals").status_code == 401
    proposal = submit(client, store)
    assert decide(client, proposal, role="planner").status_code == 403
    result = decide(client, proposal, role="self")
    assert result.status_code == 403
    assert result.json()["detail"]["code"] == "SELF_APPROVAL"


def test_approval_creates_exactly_one_incoming_lot_and_recalculates(workflow):
    client, store, _ = workflow
    before = store.read()
    proposal = submit(client, store)
    response = decide(client, proposal)
    assert response.status_code == 200
    result = response.json()
    assert (result["status"], result["version"], result["proposal"]["status"]) == ("applied", 3, "approved")
    assert result["proposal"]["execution_status"] == "demo_po_created"
    po = result["purchase_order"]
    assert po["purchase_order_id"] == result["proposal"]["purchase_order_id"]
    assert (po["status"], po["quantity"], po["supplier_id"], po["expected_delivery_date"]) == (
        "demo_created", 400, "SUP-02", "2026-12-05",
    )
    assert po["estimated_incremental_cost"] is None and po["currency"] is None
    after = store.read()
    assert after.facts.materials == before.facts.materials
    assert after.facts.incoming_lots[:-1] == before.facts.incoming_lots
    assert after.facts.incoming_lots[-1].quantity == 400
    assert after.facts.incoming_lots[-1].status == "confirmed"
    state = client.get("/state", headers=HEADERS["approver"]).json()
    assert state["version"] == 3
    target = next(item for item in state["orders"] if item["order_id"] == "ORD-1042")
    assert (target["projected_delivery_date"], target["risk"]) == ("2026-12-08", "on_track")
    listed = client.get("/proposals", headers=HEADERS["planner"]).json()
    assert listed["purchase_orders"] == [po]
    assert {entry["action"] for entry in listed["audit_logs"]} == {
        "proposal_submitted", "proposal_approved", "purchase_order_created",
    }
    assert {entry["actor_role"] for entry in listed["audit_logs"]} == {"planner", "approver"}
    assert all("timestamp" in entry and entry["proposal_id"] == proposal["proposal_id"] for entry in listed["audit_logs"])
    duplicate = decide(client, proposal)
    assert duplicate.json() == {**result, "status": "duplicate"}
    assert store.read() == after
    conflict = decide(client, proposal, decision(reason="Different reasoning."))
    assert conflict.status_code == 409 and conflict.json()["detail"]["code"] == "DECISION_ID_CONFLICT"
    repeated = decide(client, proposal, decision("new-id", expected_version=3))
    assert repeated.status_code == 409 and repeated.json()["detail"]["code"] == "PROPOSAL_DECIDED"


@pytest.mark.parametrize(("action_type", "choice", "execution_status", "audit_action"), [
    ("alternate_supplier_po", "reject", "not_executed", "proposal_rejected"),
    ("expedite_existing_lot", "approve", "awaiting_supplier_confirmation", "expedite_authorized"),
])
def test_non_inventory_decisions(workflow, action_type, choice, execution_status, audit_action):
    client, store, _ = workflow
    before = store.read()
    proposal = submit(client, store, action_type)
    response = decide(client, proposal, decision(decision=choice, acknowledge_demo_assumptions=choice == "approve"))
    assert response.status_code == 200
    result = response.json()
    assert result["version"] == 2
    assert result["purchase_order"] is None
    assert result["proposal"]["execution_status"] == execution_status
    assert store.read() == before
    assert audit_action in {entry["action"] for entry in client.get("/proposals", headers=HEADERS["planner"]).json()["audit_logs"]}


def test_stale_and_tampered_requests(workflow):
    client, store, db = workflow
    request = request_for(store)
    assert client.post("/proposals", headers=HEADERS["planner"], json={
        **request, "recommendation_id": request["recommendation_id"] + "x",
    }).status_code == 404
    assert client.post("/proposals", headers=HEADERS["planner"], json={**request, "expected_version": 1}).status_code == 409
    proposal = submit(client, store)
    assert decide(client, proposal, decision(acknowledge_demo_assumptions=False)).status_code == 422
    assert decide(client, proposal, decision(reason="   ")).status_code == 422
    assert decide(client, proposal, decision(expected_version=1)).status_code == 409

    record = db.records[(*ROOT, "proposals", proposal["proposal_id"])]
    record["recommendation"]["quantity"] += 1
    mismatch = decide(client, proposal)
    assert mismatch.status_code == 409 and mismatch.json()["detail"]["code"] == "EVIDENCE_MISMATCH"
    record["recommendation"]["quantity"] -= 1

    db.records[ROOT]["version"] = 3
    result = decide(client, proposal, decision(expected_version=3))
    assert result.status_code == 409 and result.json()["detail"]["code"] == "STALE_VERSION"
    listed = client.get("/proposals", headers=HEADERS["planner"]).json()
    assert listed["proposals"][0]["is_stale"] is True
    rejected = decide(client, proposal, decision(decision="reject", expected_version=3, acknowledge_demo_assumptions=False))
    assert rejected.status_code == 200 and rejected.json()["version"] == 3


def test_concurrent_decisions_apply_only_once(workflow):
    client, store, _ = workflow
    proposal = submit(client, store)
    request = DecisionRequest.model_validate(decision())

    def approve(_):
        try:
            return store.decide(proposal["proposal_id"], request, APPROVER).status
        except EventError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(approve, range(2))) == ["applied", "duplicate"]
    assert store.read().version == 3
    assert len(store.list_proposals().purchase_orders) == 1


def test_failed_write_rolls_back_all_records(workflow):
    client, store, db = workflow
    proposal = submit(client, store)
    audit_id = stable_id("audit", proposal["proposal_id"], "purchase_order_created")
    conflicting_path = (*ROOT, "proposal_audit", audit_id)
    db.records[conflicting_path] = {"mock": "cause transaction failure at the last audit write"}
    before = deepcopy(db.records)
    failed = decide(client, proposal)
    assert failed.status_code == 503
    assert db.records == before
    assert store.read().version == 2
    del db.records[conflicting_path]
    assert decide(client, proposal).json()["status"] == "applied"
