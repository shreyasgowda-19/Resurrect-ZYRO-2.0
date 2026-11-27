from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta

from app.inventory.models import (
    AllocationResult,
    CustomerOrder,
    InventoryInput,
    InventorySnapshot,
    MaterialAvailability,
    Reservation,
    RiskResult,
    Shortage,
)

PRIORITY = {"high": 0, "medium": 1, "low": 2}


@dataclass
class Stock:
    available_on: date
    remaining: int
    lot_id: str | None = None


def order_sequence(order: CustomerOrder) -> tuple:
    return PRIORITY[order.priority], order.crd, order.created_at, order.order_id


def predict_risk(
    order: CustomerOrder, allocation: AllocationResult, as_of_date: date
) -> RiskResult:
    ready = ship = delivery = slack = None
    if not allocation.shortages:
        ready = max((item.available_on for item in allocation.reservations), default=as_of_date)
        ship = ready + timedelta(days=order.production_days)
        delivery = ship + timedelta(days=order.transit_days)
        slack = (order.crd - delivery).days

    if order.crd < as_of_date:
        risk = "delayed"
    elif slack is None or slack < 0:
        risk = "critical"
    elif slack < 2:
        risk = "at_risk"
    else:
        risk = "on_track"

    return RiskResult(
        order_id=order.order_id,
        material_ready_date=ready,
        projected_ship_date=ship,
        projected_delivery_date=delivery,
        slack_days=slack,
        risk=risk,
    )


def allocate(order: CustomerOrder, stock_by_material: dict[str, list[Stock]]) -> AllocationResult:
    shortages = []
    pending = []
    for requirement in sorted(order.requirements, key=lambda item: item.material_id):
        remaining = requirement.quantity
        for stock in stock_by_material[requirement.material_id]:
            quantity = min(remaining, stock.remaining)
            if quantity:
                pending.append((stock, Reservation(
                    material_id=requirement.material_id,
                    quantity=quantity,
                    available_on=stock.available_on,
                    lot_id=stock.lot_id,
                )))
                remaining -= quantity
            if remaining == 0:
                break
        if remaining:
            shortages.append(Shortage(
                material_id=requirement.material_id,
                required=requirement.quantity,
                available=requirement.quantity - remaining,
            ))

    if shortages:
        return AllocationResult(order_id=order.order_id, reservations=(), shortages=tuple(shortages))

    for stock, reservation in pending:
        stock.remaining -= reservation.quantity
    return AllocationResult(
        order_id=order.order_id,
        reservations=tuple(reservation for _, reservation in pending),
        shortages=(),
    )


def calculate_inventory(inventory: InventoryInput) -> InventorySnapshot:
    stock = {
        material.material_id: [Stock(inventory.as_of_date, material.on_hand)]
        for material in inventory.materials
    }
    incoming: dict[str, int] = defaultdict(int)
    for lot in sorted(inventory.incoming_lots, key=lambda item: (item.expected_arrival, item.lot_id)):
        if lot.status == "confirmed" and lot.expected_arrival >= inventory.as_of_date:
            stock[lot.material_id].append(Stock(lot.expected_arrival, lot.quantity, lot.lot_id))
            incoming[lot.material_id] += lot.quantity

    allocations = []
    risks = []
    for order in sorted(inventory.orders, key=order_sequence):
        allocation = allocate(order, stock)
        allocations.append(allocation)
        risks.append(predict_risk(order, allocation, inventory.as_of_date))

    availability = []
    for item in sorted(inventory.materials, key=lambda material: material.material_id):
        net = sum(source.remaining for source in stock[item.material_id])
        availability.append(MaterialAvailability(
            material_id=item.material_id,
            on_hand=item.on_hand,
            eligible_incoming=incoming[item.material_id],
            allocated=item.on_hand + incoming[item.material_id] - net,
            net_availability=net,
        ))

    return InventorySnapshot(
        **inventory.model_dump(),
        availability=tuple(availability),
        allocations=tuple(allocations),
        risks=tuple(risks),
    )
