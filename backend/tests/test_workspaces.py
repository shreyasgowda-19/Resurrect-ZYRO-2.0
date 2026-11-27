from datetime import date
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app import firebase_service, workspace_store as module
from app.inventory.demo import demo_inventory
from app.inventory.events import DemoState
from app.inventory.store import StateUnavailable
from app.main import app
from scripts.evaluation_firestore import Collection, MemoryFirestore


@pytest.fixture
def operational(monkeypatch):
    db = MemoryFirestore(DemoState(version=1, facts=demo_inventory()))
    firestore = SimpleNamespace(
        collection=lambda name: Collection(db, (name,)),
        transaction=db.transaction,
    )
    monkeypatch.setattr(module, "firestore_client", lambda: firestore)
    monkeypatch.setattr(module, "transactional", db.transactional)
    monkeypatch.setattr(firebase_service, "verify_token", lambda token: {
        "uid": token,
        **({"role": "approver"} if token == "demo-only" else {}),
    })
    repository = module.FirestoreWorkspaceStore()
    first = repository.initialize("First plant", date(2026, 12, 1), {"shared": "planner", "first": "approver"})
    second = repository.initialize("Second plant", date(2026, 12, 2), {"shared": "approver", "second": "planner"})
    with TestClient(app) as client:
        yield client, repository, db, first, second


def headers(uid):
    return {"Authorization": f"Bearer {uid}", "X-Role": "approver"}


def test_empty_workspace_has_its_own_identity_and_inventory(operational):
    client, _, db, first, second = operational
    assert first != second and len(first) == len(second) == 32
    info = client.get(f"/workspaces/{first}", headers=headers("shared"))
    assert info.json() == {
        "workspace_id": first, "name": "First plant", "role": "planner", "data_mode": "operational",
    }
    state = client.get(f"/workspaces/{first}/state", headers=headers("shared"))
    assert state.status_code == 200
    assert state.json() == {
        "workspace_id": first, "role": "planner", "data_mode": "operational",
        "version": 1, "as_of_date": "2026-12-01", "materials": [], "orders": [],
        "supply_lots": [], "order_requirements": [], "recent_events": [], "alerts": [],
    }
    other = client.get(f"/workspaces/{second}/state", headers=headers("shared"))
    assert other.json()["role"] == "approver"
    assert other.json()["as_of_date"] == "2026-12-02"
    assert set(path[0] for path in db.records) == {"demo", "zyro_workspaces"}


def test_no_workspace_access_from_demo_claim_or_other_membership(operational):
    client, _, db, first, second = operational
    for suffix in ("", "/state"):
        assert client.get(f"/workspaces/{first}{suffix}").status_code == 401
        assert client.get(f"/workspaces/{first}{suffix}", headers=headers("demo-only")).status_code == 403
        forbidden = client.get(f"/workspaces/{second}{suffix}", headers=headers("first"))
        unknown = client.get(f"/workspaces/{'0' * 32}{suffix}", headers=headers("first"))
        assert forbidden.status_code == unknown.status_code == 403
        assert forbidden.json() == unknown.json()
    assert client.get("/workspaces/not-a-uuid/state", headers=headers("first")).status_code == 422
    member = db.records[(module.WORKSPACES, first, "members", "first")]
    member["active"] = False
    assert client.get(f"/workspaces/{first}/state", headers=headers("first")).status_code == 403
    member.update(active=True, role="owner")
    assert client.get(f"/workspaces/{first}/state", headers=headers("first")).status_code == 403


def test_workspace_routes_do_not_expose_mutations_and_fail_closed_on_storage_error(operational):
    client, _, db, first, second = operational
    assert client.post(f"/workspaces/{first}/state", headers=headers("first"), json={}).status_code == 405
    assert client.post("/workspaces", headers=headers("first"), json={}).status_code == 404
    db.records[(module.WORKSPACES, first)]["inventory"]["version"] = 0
    response = client.get(f"/workspaces/{first}/state", headers=headers("first"))
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "SERVICE_UNAVAILABLE"
    assert client.get(f"/workspaces/{second}/state", headers=headers("second")).status_code == 200


def test_provisioning_is_create_only_and_atomic(operational, monkeypatch):
    _, store, db, _, _ = operational
    fixed = "e" * 32
    monkeypatch.setattr(module, "uuid4", lambda: SimpleNamespace(hex=fixed))
    member_path = (module.WORKSPACES, fixed, "members", "conflict")
    db.records[member_path] = {"active": True, "role": "planner"}
    with pytest.raises(StateUnavailable):
        store.initialize("Conflicting plant", date(2026, 12, 1), {"first": "planner", "conflict": "approver"})
    assert (module.WORKSPACES, fixed) not in db.records
    assert (module.WORKSPACES, fixed, "members", "first") not in db.records
    assert db.records[member_path]["role"] == "planner"
    with pytest.raises(ValueError):
        store.initialize("Unsafe", date(2026, 12, 1), {"../unsafe": "planner"})
