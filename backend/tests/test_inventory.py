from copy import deepcopy
from datetime import date

import pytest
from pydantic import ValidationError

from app.inventory.demo import demo_inventory
from app.inventory.engine import calculate_inventory
from app.inventory.models import InventoryInput


def demo_payload():
    return demo_inventory().model_dump(mode="json")


def by_id(items, key, value):
    return next(item for item in items if getattr(item, key) == value)


def test_copper_golden_baseline():
    snapshot = calculate_inventory(demo_inventory())
    availability = by_id(snapshot.availability, "material_id", "MAT-COPPER")
    assert (availability.on_hand, availability.eligible_incoming) == (600, 400)
    assert (availability.allocated, availability.net_availability) == (1000, 0)

    allocation = by_id(snapshot.allocations, "order_id", "ORD-1042")
    assert [(item.lot_id, item.quantity) for item in allocation.reservations] == [
        (None, 600), ("LOT-01", 400)
    ]
    result = by_id(snapshot.risks, "order_id", "ORD-1042")
    assert result.material_ready_date == date(2026, 12, 5)
    assert result.projected_ship_date == date(2026, 12, 7)
    assert result.projected_delivery_date == date(2026, 12, 8)
    assert (result.slack_days, result.risk) == (2, "on_track")


def test_copper_supplier_delay():
    payload = demo_payload()
    payload["incoming_lots"][0]["expected_arrival"] = "2026-12-08"
    snapshot = calculate_inventory(InventoryInput.model_validate(payload))
    result = by_id(snapshot.risks, "order_id", "ORD-1042")
    assert result.material_ready_date == date(2026, 12, 8)
    assert result.projected_ship_date == date(2026, 12, 10)
    assert result.projected_delivery_date == date(2026, 12, 11)
    assert (result.slack_days, result.risk) == (-1, "critical")


def test_demo_readiness_risks_and_determinism():
    inventory = demo_inventory()
    snapshot = calculate_inventory(inventory)
    assert snapshot.model_dump_json() == calculate_inventory(inventory).model_dump_json()
    assert (snapshot.data_mode, snapshot.version) == ("demo", 1)
    assert (len(snapshot.materials), len(snapshot.suppliers), len(snapshot.orders)) == (6, 4, 10)
    assert {item.risk for item in snapshot.risks} == {"on_track", "at_risk", "critical", "delayed"}
    assert by_id(snapshot.risks, "order_id", "ORD-1043").slack_days == 0
    assert by_id(snapshot.risks, "order_id", "ORD-1044").risk == "delayed"
    assert by_id(snapshot.risks, "order_id", "ORD-1045").material_ready_date == date(2026, 12, 6)
    assert inventory.materials[0].on_hand == 600


@pytest.mark.parametrize("lot_changes", [
    {"expected_arrival": "2026-11-30"},
    {"status": "received"},
    {"status": "unconfirmed"},
    {"status": "cancelled"},
])
def test_ineligible_lots_are_never_counted(lot_changes):
    payload = demo_payload()
    payload["incoming_lots"][0].update(lot_changes)
    snapshot = calculate_inventory(InventoryInput.model_validate(payload))
    availability = by_id(snapshot.availability, "material_id", "MAT-COPPER")
    assert (availability.eligible_incoming, availability.allocated, availability.net_availability) == (0, 0, 600)
    allocation = by_id(snapshot.allocations, "order_id", "ORD-1042")
    assert allocation.reservations == ()
    assert [(item.material_id, item.quantity) for item in allocation.shortages] == [("MAT-COPPER", 400)]
    risk = by_id(snapshot.risks, "order_id", "ORD-1042")
    assert (risk.material_ready_date, risk.projected_ship_date, risk.projected_delivery_date, risk.slack_days) == (
        None, None, None, None
    )
    assert risk.risk == "critical"


def test_priority_and_all_or_nothing_allocation():
    payload = demo_payload()
    base = payload["orders"][0]
    payload["orders"] = [
        dict(base, order_id="LOW", priority="low", crd="2026-12-02"),
        dict(base, order_id="SECOND", priority="medium", crd="2026-12-09"),
        dict(base, order_id="UNFULFILLABLE", requirements=[
            {"material_id": "MAT-COPPER", "quantity": 1000},
            {"material_id": "MAT-RESIN", "quantity": 100},
            {"material_id": "MAT-STEEL", "quantity": 300},
        ]),
    ]

    snapshot = calculate_inventory(InventoryInput.model_validate(payload))
    failed, second, third = snapshot.allocations
    assert (failed.order_id, second.order_id, third.order_id) == ("UNFULFILLABLE", "SECOND", "LOW")
    assert failed.reservations == ()
    assert [(item.material_id, item.quantity) for item in failed.shortages] == [
        ("MAT-RESIN", 5), ("MAT-STEEL", 20)
    ]
    assert sum(item.quantity for item in second.reservations) == 1000
    assert third.reservations == ()
    assert third.shortages[0].quantity == 1000


def test_allocation_tie_breakers_and_same_day_lots():
    payload = demo_payload()
    base = payload["orders"][0]
    requirement = [{"material_id": "MAT-COPPER", "quantity": 800}]
    lot = payload["incoming_lots"][0]
    payload["incoming_lots"] = [
        dict(lot, lot_id="LOT-B", quantity=200, expected_arrival="2026-12-01"),
        dict(lot, lot_id="LOT-A", quantity=100, expected_arrival="2026-12-01"),
    ]
    payload["orders"] = [
        dict(base, order_id="LATER-CRD", crd="2026-12-09", requirements=requirement),
        dict(base, order_id="LATER-CREATED", crd="2026-12-08", created_at="2026-11-20T09:00:00Z",
             requirements=requirement),
        dict(base, order_id="B", crd="2026-12-08", requirements=requirement),
        dict(base, order_id="A", crd="2026-12-08", requirements=requirement),
    ]

    snapshot = calculate_inventory(InventoryInput.model_validate(payload))
    assert [item.order_id for item in snapshot.allocations] == ["A", "B", "LATER-CREATED", "LATER-CRD"]
    first = snapshot.allocations[0]
    assert [(item.lot_id, item.quantity) for item in first.reservations] == [
        (None, 600), ("LOT-A", 100), ("LOT-B", 100)
    ]
    assert snapshot.allocations[1].shortages[0].quantity == 700


def test_delayed_takes_precedence_over_shortage():
    payload = demo_payload()
    payload["orders"][0]["crd"] = "2026-11-30"
    payload["incoming_lots"][0]["status"] = "unconfirmed"
    snapshot = calculate_inventory(InventoryInput.model_validate(payload))
    result = by_id(snapshot.risks, "order_id", "ORD-1042")
    assert (result.risk, result.projected_delivery_date, result.slack_days) == ("delayed", None, None)


@pytest.mark.parametrize(("collection", "field", "invalid"), [
    ("materials", "on_hand", -1),
    ("materials", "on_hand", 1.0),
    ("materials", "on_hand", True),
    ("incoming_lots", "expected_arrival", "2026-11-31"),
    ("incoming_lots", "expected_arrival", "2026-12-05T00:00:00"),
    ("incoming_lots", "material_id", "unknown"),
    ("incoming_lots", "supplier_id", "unknown"),
    ("orders", "created_at", "2026-11-25T09:00:00"),
    ("orders", "crd", "12/10/2026"),
    ("orders", "requirements", [{"material_id": "unknown", "quantity": 1}]),
    ("orders", "requirements", [
        {"material_id": "MAT-COPPER", "quantity": 1},
        {"material_id": "MAT-COPPER", "quantity": 2},
    ]),
])
def test_invalid_data_rejected(collection, field, invalid):
    payload = demo_payload()
    payload[collection][0][field] = invalid
    with pytest.raises(ValidationError):
        InventoryInput.model_validate(payload)


@pytest.mark.parametrize("collection", ["materials", "suppliers", "orders", "incoming_lots"])
def test_duplicate_ids_rejected(collection):
    payload = demo_payload()
    payload[collection].append(deepcopy(payload[collection][0]))
    with pytest.raises(ValidationError, match="Duplicate identifier"):
        InventoryInput.model_validate(payload)
