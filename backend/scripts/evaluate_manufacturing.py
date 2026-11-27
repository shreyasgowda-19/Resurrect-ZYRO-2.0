"""Evaluate synthetic manufacturing cases and benchmark the real backend logic locally."""

import argparse
import json
import platform
from datetime import UTC, datetime
from time import perf_counter
from unittest.mock import patch

from app.auth import AuthenticatedUser
from app.inventory.demo import demo_inventory
from app.inventory.engine import calculate_inventory
from app.inventory.events import DemoState, EtaEvent, Event, EventError, OrderEvent, StockEvent, apply_event
from app.inventory.models import InventoryInput
from app.inventory.proposal_models import DecisionRequest
from app.inventory.proposal_store import FirestoreProposalStore
from app.inventory.recovery import evaluate_candidates, simulate
from app.inventory.recovery_models import SimulationRequest
from scripts.benchmark_inventory_reads import latency
from scripts.evaluation_firestore import ROOT, Document, MemoryFirestore

NOW = datetime(2026, 12, 1, tzinfo=UTC)
TARGET = "ORD-1042"
COLLATERAL = "ORD-EVAL-LOW"
PLANNER = AuthenticatedUser(uid="evaluation-planner", email=None, role="planner")
APPROVER = AuthenticatedUser(uid="evaluation-approver", email=None, role="approver")


def event_state(state: DemoState, event: Event) -> DemoState:
    return apply_event(state, event, NOW)[0]


def outcome(snapshot, order_id: str = TARGET) -> dict:
    result = next(item for item in snapshot.risks if item.order_id == order_id)
    return {
        "delivery": result.projected_delivery_date.isoformat() if result.projected_delivery_date else None,
        "slack": result.slack_days,
        "risk": result.risk,
    }


def shortages(snapshot, order_id: str) -> dict:
    allocation = next(item for item in snapshot.allocations if item.order_id == order_id)
    return {item.material_id: item.quantity for item in allocation.shortages}


def evaluate() -> dict:
    scenarios = []

    def compare(name: str, expected: dict, actual: dict) -> None:
        scenarios.append({"scenario": name, "expected": expected, "actual": actual, "passed": actual == expected})

    facts = demo_inventory().model_dump()
    original = next(item for item in facts["orders"] if item["order_id"] == TARGET)
    facts["orders"] = (*facts["orders"], {
        **original,
        "order_id": COLLATERAL,
        "customer_name": "Synthetic collateral customer",
        "priority": "low",
        "requirements": ({"material_id": "MAT-COPPER", "quantity": 400},),
    })
    initial = DemoState(version=1, facts=InventoryInput.model_validate(facts))
    baseline = calculate_inventory(initial.facts)
    copper = next(item for item in baseline.availability if item.material_id == "MAT-COPPER")
    before = outcome(baseline)
    compare("normal_availability", {
        "on_hand": 600, "eligible_incoming": 400, "allocated": 1000, "net": 0,
        "delivery": "2026-12-08", "slack": 2, "risk": "on_track",
    }, {
        "on_hand": copper.on_hand, "eligible_incoming": copper.eligible_incoming,
        "allocated": copper.allocated, "net": copper.net_availability, **before,
    })

    delayed = event_state(initial, EtaEvent(
        event_id="evaluation-delay", event_type="supplier_eta_update", expected_version=1,
        payload={"lot_id": "LOT-01", "new_eta": "2026-12-08"},
    ))
    delayed_snapshot = calculate_inventory(delayed.facts)
    disrupted = outcome(delayed_snapshot)
    compare("supplier_delay", {"delivery": "2026-12-11", "slack": -1, "risk": "critical"}, disrupted)

    compare("material_shortage", {"shortages": {"MAT-RESIN": 30}, "risk": "critical"}, {
        "shortages": shortages(baseline, "ORD-1046"), "risk": outcome(baseline, "ORD-1046")["risk"],
    })

    demand = event_state(initial, OrderEvent(
        event_id="evaluation-demand", event_type="order_change", expected_version=1,
        payload={"order_id": TARGET, "material_id": "MAT-COPPER", "new_required_quantity": 1200},
    ))
    calculated = calculate_inventory(demand.facts)
    compare("demand_increase", {"shortages": {"MAT-COPPER": 200}, "delivery": None}, {
        "shortages": shortages(calculated, TARGET), "delivery": outcome(calculated)["delivery"],
    })

    adjusted = event_state(initial, StockEvent(
        event_id="evaluation-stock", event_type="stock_adjustment", expected_version=1,
        payload={"material_id": "MAT-COPPER", "quantity_delta": -50},
    ))
    calculated = calculate_inventory(adjusted.facts)
    compare("stock_discrepancy", {"on_hand": 550, "shortages": {"MAT-COPPER": 50}}, {
        "on_hand": next(item.on_hand for item in calculated.materials if item.material_id == "MAT-COPPER"),
        "shortages": shortages(calculated, TARGET),
    })

    candidates = {
        item.recommendation.action_type: item.recommendation
        for item in evaluate_candidates(delayed, TARGET)
    }
    alternate = candidates["alternate_supplier_po"]
    expedite = candidates["expedite_existing_lot"]
    alternatives = {item.action_type: simulate(delayed, TARGET, item.recommendation_id) for item in candidates.values()}
    compare("recovery_simulation", {
        "expedite_existing_lot": "2026-12-08", "alternate_supplier_po": "2026-12-08",
        "both_hypothetical": True,
    }, {
        **{action: result.after.projected_delivery_date.isoformat() for action, result in alternatives.items()},
        "both_hypothetical": all(result.hypothetical for result in alternatives.values()),
    })
    collateral = alternatives["alternate_supplier_po"].affected_orders
    compare("collateral_impact", {"orders": [{
        "order_id": COLLATERAL, "before_delivery": None, "after_delivery": "2026-12-11",
        "before_risk": "critical", "after_risk": "critical",
    }]}, {"orders": [{
        "order_id": item.order_id,
        "before_delivery": item.before.projected_delivery_date.isoformat() if item.before.projected_delivery_date else None,
        "after_delivery": item.after.projected_delivery_date.isoformat() if item.after.projected_delivery_date else None,
        "before_risk": item.before.risk,
        "after_risk": item.after.risk,
    } for item in collateral]})

    db = MemoryFirestore(delayed)
    store = FirestoreProposalStore()
    with (
        patch("app.inventory.proposal_store.transactional", db.transactional),
        patch.object(store, "_references", return_value=(db, Document(db, ROOT))),
    ):
        def propose(rec):
            return store.create_proposal(SimulationRequest(
                order_id=TARGET, recommendation_id=rec.recommendation_id, expected_version=2,
            ), PLANNER).proposal

        advance = propose(alternate)
        stale = propose(expedite)
        request = DecisionRequest(
            decision_id="evaluation-approval", decision="approve", expected_version=2,
            reason="Review simulated supplier assumptions.", acknowledge_demo_assumptions=True,
        )
        approved = store.decide(advance.proposal_id, request, APPROVER)
        recovered = store.read()
        result = calculate_inventory(recovered.facts)
        recovered_outcome = outcome(result)
        lot_delta = sum(item.quantity for item in recovered.facts.incoming_lots) - sum(
            item.quantity for item in delayed.facts.incoming_lots
        )
        compare("authorized_recovery", {
            "version": 3, "status": "applied", "physical_stock_unchanged": True,
            "added_incoming": 400, "delivery": "2026-12-08", "slack": 2, "risk": "on_track",
        }, {
            "version": approved.version, "status": approved.status,
            "physical_stock_unchanged": recovered.facts.materials == delayed.facts.materials,
            "added_incoming": lot_delta, **recovered_outcome,
        })
        replays = [store.decide(advance.proposal_id, request, APPROVER) for _ in range(3)]
        po_count = len(store.list_proposals().purchase_orders)
        duplicate_orders = po_count - 1
        compare("duplicate_po_prevention", {
            "statuses": ["duplicate"] * 3, "po_count": 1, "duplicate_pos": 0, "inventory_unchanged": True,
        }, {
            "statuses": [item.status for item in replays], "po_count": po_count,
            "duplicate_pos": duplicate_orders, "inventory_unchanged": store.read() == recovered,
        })

        stale_request = request.model_copy(update={"decision_id": "evaluation-stale", "expected_version": 3})
        error_status, error_code = None, None
        try:
            store.decide(stale.proposal_id, stale_request, APPROVER)
        except EventError as error:
            error_status, error_code = error.status, error.code
        compare("stale_approval", {"http": 409, "code": "STALE_VERSION", "inventory_unchanged": True}, {
            "http": error_status, "code": error_code, "inventory_unchanged": store.read() == recovered,
        })

    return {
        "scenarios": scenarios,
        "impact": {
            "before": before,
            "disrupted": disrupted,
            "authorized": recovered_outcome,
            "slack_improvement_days": recovered_outcome["slack"] - disrupted["slack"],
            "added_incoming_quantity": lot_delta,
            "other_orders_changed_during_approval": [
                item.order_id for item in result.risks
                if item.order_id != TARGET and outcome(result, item.order_id)
                != outcome(delayed_snapshot, item.order_id)
            ],
            "duplicate_purchase_orders": duplicate_orders,
        },
    }


def benchmark(operation, samples: int) -> dict:
    readings = []
    for _ in range(samples):
        started = perf_counter()
        operation()
        readings.append((perf_counter() - started) * 1000)
    return latency(readings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, choices=range(1, 201), default=21)
    args = parser.parse_args()
    result = evaluate()
    facts = demo_inventory()
    result["environment"] = f"{platform.platform()}, Python {platform.python_version()}"
    result["engine_latency"] = benchmark(lambda: calculate_inventory(facts), args.samples)
    result["full_evaluation_latency"] = benchmark(evaluate, args.samples)
    print(json.dumps(result, indent=2))
    return 0 if all(case["passed"] for case in result["scenarios"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
