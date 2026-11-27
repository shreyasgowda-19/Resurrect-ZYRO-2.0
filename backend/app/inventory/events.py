from datetime import datetime
from typing import Annotated, Literal

from pydantic import Field, model_validator

from app.inventory.engine import calculate_inventory
from app.inventory.models import (
    CalendarDate, Identifier, InventoryInput, InventoryModel, MAX_QUANTITY, PositiveQuantity,
    Quantity, Risk, Timestamp,
)

EventType = Literal["supplier_eta_update", "material_receipt", "stock_adjustment", "order_change"]
RISK_SEVERITY = {"on_track": 0, "at_risk": 1, "critical": 2, "delayed": 3}
HISTORY_LIMIT = 20


class EventError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code


class EtaPayload(InventoryModel):
    lot_id: Identifier
    new_eta: CalendarDate


class ReceiptPayload(InventoryModel):
    lot_id: Identifier
    quantity: PositiveQuantity


class StockPayload(InventoryModel):
    material_id: Identifier
    quantity_delta: Annotated[int, Field(strict=True, ge=-MAX_QUANTITY - 1, le=MAX_QUANTITY)]

    @model_validator(mode="after")
    def check_delta(self):
        if self.quantity_delta == 0:
            raise ValueError("Quantity delta must be nonzero")
        return self


class OrderPayload(InventoryModel):
    order_id: Identifier
    new_crd: CalendarDate | None = None
    material_id: Identifier | None = None
    new_required_quantity: Quantity | None = None

    @model_validator(mode="after")
    def check_changes(self):
        if (self.material_id is None) != (self.new_required_quantity is None):
            raise ValueError("Material ID and required quantity must be supplied together")
        if self.new_crd is None and self.material_id is None:
            raise ValueError("Specify at least one order change")
        return self


class EventBase(InventoryModel):
    event_id: Annotated[str, Field(min_length=1, max_length=256)]
    expected_version: PositiveQuantity


class EtaEvent(EventBase):
    event_type: Literal["supplier_eta_update"]
    payload: EtaPayload


class ReceiptEvent(EventBase):
    event_type: Literal["material_receipt"]
    payload: ReceiptPayload


class StockEvent(EventBase):
    event_type: Literal["stock_adjustment"]
    payload: StockPayload


class OrderEvent(EventBase):
    event_type: Literal["order_change"]
    payload: OrderPayload


Event = Annotated[EtaEvent | ReceiptEvent | StockEvent | OrderEvent, Field(discriminator="event_type")]


class EventResult(InventoryModel):
    event_id: Identifier
    status: Literal["applied", "duplicate"]
    version: PositiveQuantity


class EventSummary(InventoryModel):
    event_id: Identifier
    event_type: EventType
    summary: str
    version: PositiveQuantity
    recorded_at: Timestamp


class RiskAlert(InventoryModel):
    alert_id: Identifier
    order_id: Identifier
    previous_risk: Risk
    new_risk: Risk
    message: str
    event_id: Identifier
    version: PositiveQuantity


class DemoState(InventoryModel):
    version: PositiveQuantity
    facts: InventoryInput
    recent_events: tuple[EventSummary, ...] = ()
    alerts: tuple[RiskAlert, ...] = ()


def find_entity(items, key: str, identifier: str):
    for item in items:
        if item[key] == identifier:
            return item
    raise EventError(404, "NOT_FOUND", f"No {key.removesuffix('_id')} found for {identifier}.")


def apply_to_facts(facts: InventoryInput, event: Event) -> tuple[InventoryInput, str]:
    updated = facts.model_dump()
    payload = event.payload
    if isinstance(payload, (EtaPayload, ReceiptPayload)):
        lot = find_entity(updated["incoming_lots"], "lot_id", payload.lot_id)
        if isinstance(payload, EtaPayload):
            if lot["status"] != "confirmed" or lot["quantity"] == 0:
                raise EventError(422, "INVALID_OPERATION", "The lot has no confirmed outstanding quantity.")
            if payload.new_eta < facts.as_of_date:
                raise EventError(422, "INVALID_OPERATION", "ETA cannot precede the demo date.")
            old_eta = lot["expected_arrival"]
            lot["expected_arrival"] = payload.new_eta
            summary = f"Lot {payload.lot_id} ETA changed from {old_eta} to {payload.new_eta}."
        else:
            if lot["status"] not in ("confirmed", "unconfirmed") or payload.quantity > lot["quantity"]:
                raise EventError(422, "INVALID_OPERATION", "Receipt exceeds the lot's outstanding quantity.")
            material = find_entity(updated["materials"], "material_id", lot["material_id"])
            material["on_hand"] += payload.quantity
            lot["quantity"] -= payload.quantity
            if lot["quantity"] == 0:
                lot["status"] = "received"
            summary = f"Received {payload.quantity} units of {lot['material_id']} from lot {payload.lot_id}."
    elif isinstance(payload, StockPayload):
        material = find_entity(updated["materials"], "material_id", payload.material_id)
        new_quantity = material["on_hand"] + payload.quantity_delta
        if new_quantity < 0:
            raise EventError(422, "INVALID_OPERATION", "Physical stock cannot be negative.")
        material["on_hand"] = new_quantity
        summary = f"Adjusted {payload.material_id} by {payload.quantity_delta:+d} to {new_quantity} on hand."
    else:
        order = find_entity(updated["orders"], "order_id", payload.order_id)
        changes = []
        if payload.material_id is not None:
            find_entity(updated["materials"], "material_id", payload.material_id)
            requirement = find_entity(order["requirements"], "material_id", payload.material_id)
            requirement["quantity"] = payload.new_required_quantity
            changes.append(f"{payload.material_id} requirement to {payload.new_required_quantity}")
        if payload.new_crd is not None:
            order["crd"] = payload.new_crd
            changes.append(f"CRD to {payload.new_crd}")
        summary = f"Changed order {payload.order_id}: {', '.join(changes)}."

    return InventoryInput.model_validate(updated), summary


def apply_event(
    state: DemoState, event: Event, recorded_at: datetime
) -> tuple[DemoState, tuple[RiskAlert, ...]]:
    if state.version != event.expected_version:
        raise EventError(409, "STALE_VERSION", "Refresh the dashboard before submitting another event.")

    facts, summary = apply_to_facts(state.facts, event)
    previous = {risk.order_id: risk.risk for risk in calculate_inventory(state.facts).risks}
    current = calculate_inventory(facts)
    orders = {order.order_id: order for order in facts.orders}
    allocations = {item.order_id: item for item in current.allocations}
    version = state.version + 1
    alerts = []
    for risk in current.risks:
        prior = previous[risk.order_id]
        if RISK_SEVERITY[risk.risk] <= RISK_SEVERITY[prior]:
            continue

        order = orders[risk.order_id]
        if risk.risk == "delayed":
            reason = f"CRD {order.crd} precedes the snapshot date {facts.as_of_date}."
        elif risk.slack_days is None:
            shortages = allocations[risk.order_id].shortages
            reason = "Unresolved shortages: " + ", ".join(
                f"{item.material_id} short by {item.quantity}" for item in shortages
            ) + "."
        else:
            reason = f"Projected delivery {risk.projected_delivery_date} against CRD {order.crd} gives {risk.slack_days} days of slack."

        alerts.append(RiskAlert(
            alert_id=f"{version}-{risk.order_id}",
            order_id=risk.order_id,
            previous_risk=prior,
            new_risk=risk.risk,
            message=f"{summary} {reason}",
            event_id=event.event_id,
            version=version,
        ))

    event_summary = EventSummary(
        event_id=event.event_id,
        event_type=event.event_type,
        summary=summary,
        version=version,
        recorded_at=recorded_at,
    )
    new_alerts = tuple(alerts)
    return DemoState(
        version=version,
        facts=facts,
        recent_events=(event_summary, *state.recent_events)[:HISTORY_LIMIT],
        alerts=(*new_alerts, *state.alerts)[:HISTORY_LIMIT],
    ), new_alerts
