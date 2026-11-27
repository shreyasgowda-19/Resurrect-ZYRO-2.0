from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.auth import authenticated_user
from app.inventory.proposal_store import proposal_store
from app.inventory.store import DOCUMENT, FirestoreInventoryStore, inventory_store
from scripts import run_isolated_demo


def test_initializer_requires_explicit_confirmation(monkeypatch):
    created = []
    monkeypatch.setattr(FirestoreInventoryStore, "initialize", lambda self: created.append(self.document_id) or True)

    with pytest.raises(SystemExit) as error:
        run_isolated_demo.main(["initialize", "judges-round-01"])
    assert error.value.code == 2
    assert not created

    assert run_isolated_demo.main(["initialize", "judges-round-01", "--confirm-create"]) == 0
    assert created == ["t7-demo-judges-round-01"]
    assert inventory_store().document_id == proposal_store().document_id == DOCUMENT


@pytest.mark.parametrize("name", ["current", "../current", "bad/name", "Upper", " ", "a" * 41])
def test_invalid_namespace_rejected_before_read_or_write(monkeypatch, name):
    def forbidden(*args, **kwargs):
        pytest.fail("Invalid namespace must not access Firestore")

    monkeypatch.setattr(FirestoreInventoryStore, "_references", forbidden)
    with pytest.raises(SystemExit) as error:
        run_isolated_demo.main(["initialize", name, "--confirm-create"])
    assert error.value.code == 2


def test_existing_namespace_is_not_reset(monkeypatch):
    created = []

    def initialize(self):
        created.append(self.document_id)
        return False

    monkeypatch.setattr(FirestoreInventoryStore, "initialize", initialize)
    assert run_isolated_demo.main(["initialize", "judges-round-01", "--confirm-create"]) == 1
    assert created == ["t7-demo-judges-round-01"]


def test_launcher_routes_both_stores_and_keeps_firebase_authentication(monkeypatch):
    reads = []

    def read(self):
        reads.append(self.document_id)
        return SimpleNamespace(version=1)

    def run(api, *, host, port):
        assert host == "127.0.0.1"
        assert port == 8001
        assert api.dependency_overrides[inventory_store]().document_id == "t7-demo-judges"
        assert api.dependency_overrides[proposal_store]().document_id == "t7-demo-judges"
        assert authenticated_user not in api.dependency_overrides
        with TestClient(api) as client:
            assert client.get("/health").status_code == 200
            assert client.get("/state").status_code == 401
            assert client.get("/proposals").status_code == 401
            assert client.get("/ai/briefing").status_code == 401

    monkeypatch.setattr(FirestoreInventoryStore, "read", read)
    monkeypatch.setattr(run_isolated_demo.uvicorn, "run", run)
    original = run_isolated_demo.app.dependency_overrides
    assert run_isolated_demo.main(["serve", "judges"]) == 0
    assert reads == ["t7-demo-judges"]
    assert run_isolated_demo.app.dependency_overrides is original


def test_serve_does_not_seed_a_missing_namespace(monkeypatch):
    from app.inventory.store import StateUnavailable

    def missing(self):
        assert self.document_id == "t7-demo-missing"
        raise StateUnavailable("Demo inventory has not been initialized.")

    def forbidden(*args, **kwargs):
        pytest.fail("Serving a missing namespace must not initialize data or start the server")

    monkeypatch.setattr(FirestoreInventoryStore, "read", missing)
    monkeypatch.setattr(FirestoreInventoryStore, "initialize", forbidden)
    monkeypatch.setattr(run_isolated_demo.uvicorn, "run", forbidden)
    assert run_isolated_demo.main(["serve", "missing"]) == 1
