from copy import deepcopy

from app.inventory.proposals import stable_id
from app.workspace_store import WORKSPACES
from test_workspaces import headers, operational


def create_body(**fields):
    return {
        "material_id": "resin-01", "name": "Production resin", "unit": "kg",
        "reorder_threshold": 15, "description": "Blue formulation",
        "expected_version": 1, "mutation_id": "create-resin", **fields,
    }


def patch_body(**fields):
    return {"expected_version": 2, "mutation_id": "edit-resin", "name": "Revised resin", **fields}


def board(client, workspace, user="shared"):
    return client.get(f"/workspaces/{workspace}/state", headers=headers(user)).json()


def test_create_edit_persist_and_audit_without_stock_changes(operational):
    client, _, db, first, second = operational
    path = f"/workspaces/{first}/materials"
    before = deepcopy(db.records[("demo", "isolated")])
    del db.records[(WORKSPACES, first)]["material_metadata"]  # Existing T8.1 workspace.
    created = client.post(path, json=create_body(), headers=headers("shared"))
    assert created.status_code == 200
    first_result = created.json()
    assert (first_result["version"], first_result["status"], first_result["workspace_id"]) == (2, "applied", first)
    assert first_result["material"] == {
        "material_id": "RESIN-01", "name": "Production resin", "unit": "kg",
        "on_hand": 0, "incoming": 0, "allocated": 0, "net_available": 0,
        "reorder_threshold": 15, "description": "Blue formulation",
    }
    updated = client.patch(
        path + "/resin-01", json=patch_body(reorder_threshold=20, description=None),
        headers=headers("shared"),
    )
    assert updated.status_code == 200
    material = updated.json()["material"]
    assert (updated.json()["version"], material["name"], material["on_hand"], material["unit"]) == (3, "Revised resin", 0, "kg")
    assert (material["reorder_threshold"], material["description"]) == (20, None)
    assert board(client, first, "first")["materials"] == [material]
    assert board(client, second, "second")["materials"] == []

    replay = client.post(path, json=create_body(material_id="RESIN-01"), headers=headers("shared"))
    assert replay.json() == {**first_result, "status": "duplicate"}
    audits = [value for key, value in db.records.items() if key[:3] == (WORKSPACES, first, "material_audit")]
    assert [event["action"] for event in audits] == ["material_created", "material_updated"]
    assert [event["version"] for event in audits] == [2, 3]
    assert all(event["actor_uid"] == "shared" and event["actor_role"] == "planner" for event in audits)
    assert audits[0]["before"] is None and audits[1]["before"]["reorder_threshold"] == 15
    assert db.records[("demo", "isolated")] == before


def test_roles_cross_workspace_version_and_validation(operational):
    client, _, db, first, second = operational
    path = f"/workspaces/{first}/materials"
    assert client.post(path, json=create_body()).status_code == 401
    assert client.post(path, json=create_body(), headers=headers("first")).status_code == 403
    assert client.post(path, json=create_body(), headers=headers("second")).status_code == 403
    assert client.post(f"/workspaces/{second}/materials", json=create_body(), headers=headers("shared")).status_code == 403
    for invalid in (
        {"material_id": "bad/id"}, {"name": "  "}, {"unit": ""}, {"reorder_threshold": -1},
        {"reorder_threshold": True}, {"on_hand": 100}, {"description": "x" * 501},
    ):
        assert client.post(path, json=create_body(**invalid), headers=headers("shared")).status_code == 422
    assert client.post(path, json=create_body(), headers=headers("shared")).status_code == 200
    assert client.patch(path + "/RESIN-01", json=patch_body(), headers=headers("first")).status_code == 403
    assert client.patch(path + "/RESIN-01", json=patch_body(), headers=headers("second")).status_code == 403
    before_duplicate = deepcopy(db.records)
    for sku in ("RESIN-01", "ReSiN-01"):
        duplicate = client.post(
            path, json=create_body(material_id=sku, mutation_id="new", expected_version=2),
            headers=headers("shared"),
        )
        assert (duplicate.status_code, duplicate.json()["detail"]["code"]) == (409, "DUPLICATE_MATERIAL")
        assert db.records == before_duplicate
    conflict = client.post(path, json=create_body(name="Different"), headers=headers("shared"))
    assert (conflict.status_code, conflict.json()["detail"]["code"]) == (409, "MUTATION_ID_CONFLICT")
    stale = client.patch(path + "/RESIN-01", json=patch_body(expected_version=1), headers=headers("shared"))
    assert (stale.status_code, stale.json()["detail"]["code"]) == (409, "STALE_VERSION")
    assert client.patch(path + "/MISSING", json=patch_body(), headers=headers("shared")).status_code == 404
    for invalid in ({"on_hand": 2}, {"material_id": "OTHER"}, {"name": None}, {"reorder_threshold": -4}):
        assert client.patch(path + "/RESIN-01", json=patch_body(**invalid), headers=headers("shared")).status_code == 422
    assert client.patch(path + "/RESIN-01", json={"expected_version": 2, "mutation_id": "empty"}, headers=headers("shared")).status_code == 422
    db.records[(WORKSPACES, first, "members", "shared")]["active"] = False
    assert client.post(path, json=create_body(), headers=headers("shared")).status_code == 403
    assert board(client, first, "first")["version"] == 2


def test_edit_preserves_existing_stock_and_rolls_back_when_audit_fails(operational):
    client, _, db, first, _ = operational
    path = f"/workspaces/{first}/materials"
    assert client.post(path, json=create_body(), headers=headers("shared")).status_code == 200
    db.records[(WORKSPACES, first)]["inventory"]["facts"]["materials"][0]["on_hand"] = 12
    audit_path = (WORKSPACES, first, "material_audit", stable_id("material-mutation", "edit-resin"))
    db.records[audit_path] = {"fixture": True}
    before = deepcopy(db.records)
    assert client.patch(path + "/RESIN-01", json=patch_body(), headers=headers("shared")).status_code == 503
    assert db.records == before
    del db.records[audit_path]
    updated = client.patch(path + "/RESIN-01", json=patch_body(), headers=headers("shared"))
    assert updated.status_code == 200
    assert updated.json()["material"]["on_hand"] == 12
    assert board(client, first)["materials"][0]["on_hand"] == 12
