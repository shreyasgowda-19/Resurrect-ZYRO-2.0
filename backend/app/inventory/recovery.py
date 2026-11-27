"""Deterministic recovery candidates evaluated by the canonical allocation engine."""

import json
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from hashlib import sha256

from pydantic import ValidationError

from app.inventory.engine import calculate_inventory
from app.inventory.events import DemoState, EventError, RISK_SEVERITY
from app.inventory.models import CustomerOrder, InventoryInput, InventorySnapshot, SupplyLot
from app.inventory.recovery_models import (
    ActionType, AffectedOrder, OrderOutcome, Recommendation, SimulationResponse,
)

# Synthetic Copper capability for a supplier already present in the demo facts.
DEMO_ALTERNATE_MATERIAL = "MAT-COPPER"
DEMO_ALTERNATE_SUPPLIER = "SUP-02"
DEMO_ALTERNATE_LEAD_DAYS = 4
DEMO_ALTERNATE_CAPACITY = 400


@dataclass(frozen=True)
class RecoveryAction:
    action_type: ActionType
    material_id: str
    supplier_id: str
    lot_id: str | None
    quantity: int
    proposed_eta: date

    def recommendation_id(self, version: int, order_id: str) -> str:
        parameters = {**asdict(self), "proposed_eta": self.proposed_eta.isoformat()}
        canonical = json.dumps([version, order_id, parameters], sort_keys=True, separators=(",", ":"))
        return "rec-" + sha256(canonical.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class EvaluatedCandidate:
    recommendation: Recommendation
    before: dict[str, OrderOutcome]
    after: dict[str, OrderOutcome]


def outcomes(snapshot: InventorySnapshot) -> dict[str, OrderOutcome]:
    return {
        item.order_id: OrderOutcome(
            projected_ship_date=item.projected_ship_date,
            projected_delivery_date=item.projected_delivery_date,
            slack_days=item.slack_days,
            risk=item.risk,
        )
        for item in snapshot.risks
    }


def improves(before: OrderOutcome, after: OrderOutcome) -> bool:
    if before.risk != after.risk:
        return RISK_SEVERITY[after.risk] < RISK_SEVERITY[before.risk]
    return after.projected_delivery_date is not None and (
        before.projected_delivery_date is None or after.projected_delivery_date < before.projected_delivery_date
    )


def hypothetical_facts(facts: InventoryInput, action: RecoveryAction, recommendation_id: str) -> InventoryInput:
    draft = facts.model_dump()
    lots = draft["incoming_lots"]
    if action.action_type == "expedite_existing_lot":
        lot = next(item for item in lots if item["lot_id"] == action.lot_id)
        lot["expected_arrival"] = action.proposed_eta
    else:
        lots = (*lots, SupplyLot(
            lot_id=f"hypothetical-{recommendation_id}",
            material_id=action.material_id,
            supplier_id=action.supplier_id,
            quantity=action.quantity,
            expected_arrival=action.proposed_eta,
            status="confirmed",
        ).model_dump())
        draft["incoming_lots"] = lots
    return InventoryInput.model_validate(draft)


def actions(baseline: InventorySnapshot, order: CustomerOrder) -> Iterator[RecoveryAction]:
    required = {item.material_id: item.quantity for item in order.requirements if item.quantity}
    lots = sorted(baseline.incoming_lots, key=lambda lot: (lot.expected_arrival, lot.lot_id))
    allocation = next(item for item in baseline.allocations if item.order_id == order.order_id)
    physical_copper = sum(
        item.quantity for item in allocation.reservations
        if item.lot_id is None and item.material_id == DEMO_ALTERNATE_MATERIAL
    )
    for lot in lots:
        if lot.material_id not in required or lot.status != "confirmed" or lot.expected_arrival <= baseline.as_of_date:
            continue
        # Hypothetical acceleration only. There is no carrier or supplier confirmation.
        proposed_eta = max(baseline.as_of_date + timedelta(days=1), lot.expected_arrival - timedelta(days=3))
        if proposed_eta < lot.expected_arrival:
            yield RecoveryAction(
                "expedite_existing_lot", lot.material_id, lot.supplier_id, lot.lot_id, lot.quantity, proposed_eta
            )

    incumbent_suppliers = {lot.supplier_id for lot in lots if lot.material_id == DEMO_ALTERNATE_MATERIAL}
    has_alternate = any(supplier.supplier_id == DEMO_ALTERNATE_SUPPLIER for supplier in baseline.suppliers)
    copper_required = required.get(DEMO_ALTERNATE_MATERIAL, 0)
    copper_shortage = next(
        (item.quantity for item in allocation.shortages if item.material_id == DEMO_ALTERNATE_MATERIAL),
        None,
    )
    quantity = min(
        DEMO_ALTERNATE_CAPACITY,
        copper_shortage if copper_shortage is not None else copper_required - physical_copper,
    )
    if quantity > 0 and incumbent_suppliers and has_alternate and DEMO_ALTERNATE_SUPPLIER not in incumbent_suppliers:
        yield RecoveryAction(
            "alternate_supplier_po", DEMO_ALTERNATE_MATERIAL, DEMO_ALTERNATE_SUPPLIER, None, quantity,
            baseline.as_of_date + timedelta(days=DEMO_ALTERNATE_LEAD_DAYS),
        )


def recommendation_for(
    action: RecoveryAction,
    recommendation_id: str,
    baseline: InventorySnapshot,
    order: CustomerOrder,
    before: OrderOutcome,
    after: OrderOutcome,
) -> Recommendation:
    supplier = next(item for item in baseline.suppliers if item.supplier_id == action.supplier_id)
    requirement = next(item for item in order.requirements if item.material_id == action.material_id)
    allocation = next(item for item in baseline.allocations if item.order_id == order.order_id)
    reserved = sum(item.quantity for item in allocation.reservations if item.material_id == action.material_id)
    evidence = [
        f"Order {order.order_id} has {order.priority} priority and CRD {order.crd}.",
        f"{action.material_id}: {requirement.quantity} required and {reserved} committed to this order in the snapshot.",
        f"Baseline projected delivery: {before.projected_delivery_date or 'unavailable'} ({before.risk}).",
    ]
    if action.lot_id is not None:
        lot = next(item for item in baseline.incoming_lots if item.lot_id == action.lot_id)
        evidence.append(f"Confirmed lot {lot.lot_id} from {supplier.name} has {lot.quantity} outstanding, ETA {lot.expected_arrival}.")
        title = f"Explore expediting {lot.lot_id}"
        assumption = "Synthetic demo scenario assumes up to three days of acceleration. Supplier willingness and fees are unverified."
    else:
        evidence.append(f"{supplier.name} exists in the demo supplier register. Copper capability is a synthetic assumption.")
        title = f"Evaluate a hypothetical order from {supplier.name}"
        assumption = (
            f"Synthetic demo capability assumes up to {DEMO_ALTERNATE_CAPACITY} Copper units in "
            f"{DEMO_ALTERNATE_LEAD_DAYS} calendar days. Capacity, price, and availability are unconfirmed."
        )

    return Recommendation(
        **asdict(action),
        recommendation_id=recommendation_id,
        title=title,
        explanation=(
            f"If the proposed ETA {action.proposed_eta} is achieved, the modeled delivery is "
            f"{after.projected_delivery_date} ({after.risk}). Recovery depends on the stated assumptions."
        ),
        assumptions=(assumption, "Incremental cost and currency are unknown."),
        evidence=tuple(evidence),
    )


def evaluate_candidates(state: DemoState, order_id: str) -> tuple[EvaluatedCandidate, ...]:
    order = next((item for item in state.facts.orders if item.order_id == order_id), None)
    if order is None:
        raise EventError(404, "NOT_FOUND", "Order not found.")

    baseline = calculate_inventory(state.facts)
    before = outcomes(baseline)
    if before[order_id].risk == "on_track":
        return ()

    feasible = []
    for action in actions(baseline, order):
        recommendation_id = action.recommendation_id(state.version, order_id)
        try:
            proposed = hypothetical_facts(state.facts, action, recommendation_id)
            after = outcomes(calculate_inventory(proposed))
        except (OverflowError, ValidationError):
            continue
        if improves(before[order_id], after[order_id]):
            recommendation = recommendation_for(action, recommendation_id, baseline, order, before[order_id], after[order_id])
            feasible.append(EvaluatedCandidate(recommendation, before, after))
    return tuple(feasible)


def resolve_candidate(state: DemoState, order_id: str, recommendation_id: str) -> EvaluatedCandidate:
    candidates = evaluate_candidates(state, order_id)
    candidate = next((item for item in candidates if item.recommendation.recommendation_id == recommendation_id), None)
    if candidate is None:
        raise EventError(404, "NOT_FOUND", "Recommendation not found for this order and snapshot.")

    return candidate


def simulate(state: DemoState, order_id: str, recommendation_id: str) -> SimulationResponse:
    return simulate_candidate(state, order_id, resolve_candidate(state, order_id, recommendation_id))


def simulate_candidate(state: DemoState, order_id: str, candidate: EvaluatedCandidate) -> SimulationResponse:
    before = candidate.before[order_id]
    after = candidate.after[order_id]
    affected = tuple(
        AffectedOrder(order_id=key, before=candidate.before[key], after=result)
        for key, result in candidate.after.items()
        if key != order_id and result != candidate.before[key]
    )
    warnings = ["Hypothetical only. Supplier availability and recovery are unconfirmed."]
    if after.risk != "on_track":
        warnings.append(f"The target order remains {after.risk}.")
    if any(improves(item.after, item.before) for item in affected):
        warnings.append("The proposed action worsens at least one other order's modeled outcome.")

    recommendation = candidate.recommendation
    return SimulationResponse(
        order_id=order_id,
        recommendation_id=recommendation.recommendation_id,
        version=state.version,
        before=before,
        after=after,
        affected_orders=affected,
        estimated_incremental_cost=recommendation.estimated_incremental_cost,
        currency=recommendation.currency,
        assumptions=recommendation.assumptions,
        warnings=tuple(warnings),
    )
