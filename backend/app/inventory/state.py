from datetime import date
from typing import Annotated, Literal

from fastapi import APIRouter, Depends

from app.auth import AuthenticatedUser, authenticated_user
from app.inventory.demo import demo_inventory
from app.inventory.engine import calculate_inventory
from app.inventory.models import InventoryModel, Priority, Quantity, Risk

router = APIRouter()


class StateMaterial(InventoryModel):
    material_id: str
    name: str
    unit: str
    on_hand: Quantity
    incoming: Quantity
    allocated: Quantity
    net_available: int


class StateShortage(InventoryModel):
    material_id: str
    required: Quantity
    available: Quantity
    shortage: Quantity


class StateOrder(InventoryModel):
    order_id: str
    customer: str
    priority: Priority
    crd: date
    material_ready_date: date | None
    projected_ship_date: date | None
    projected_delivery_date: date | None
    slack_days: int | None
    risk: Risk
    shortages: tuple[StateShortage, ...]


class StateResponse(InventoryModel):
    version: Literal[1]
    as_of_date: date
    data_mode: Literal["demo"]
    materials: tuple[StateMaterial, ...]
    orders: tuple[StateOrder, ...]


@router.get("/state", response_model=StateResponse, responses={
    401: {"description": "Missing or invalid Firebase ID token"},
    403: {"description": "Unauthorized role"},
    503: {"description": "Required service unavailable"},
})
def get_state(_user: Annotated[AuthenticatedUser, Depends(authenticated_user)]) -> StateResponse:
    snapshot = calculate_inventory(demo_inventory())
    materials = {material.material_id: material for material in snapshot.materials}
    orders = {order.order_id: order for order in snapshot.orders}
    allocations = {allocation.order_id: allocation for allocation in snapshot.allocations}

    return StateResponse(
        version=snapshot.version,
        as_of_date=snapshot.as_of_date,
        data_mode=snapshot.data_mode,
        materials=tuple(
            StateMaterial(
                material_id=item.material_id,
                name=materials[item.material_id].name,
                unit=materials[item.material_id].unit,
                on_hand=item.on_hand,
                incoming=item.eligible_incoming,
                allocated=item.allocated,
                net_available=item.net_availability,
            )
            for item in snapshot.availability
        ),
        orders=tuple(
            StateOrder(
                order_id=item.order_id,
                customer=orders[item.order_id].customer_name,
                priority=orders[item.order_id].priority,
                crd=orders[item.order_id].crd,
                material_ready_date=item.material_ready_date,
                projected_ship_date=item.projected_ship_date,
                projected_delivery_date=item.projected_delivery_date,
                slack_days=item.slack_days,
                risk=item.risk,
                shortages=tuple(
                    StateShortage(
                        material_id=shortage.material_id,
                        required=shortage.required,
                        available=shortage.available,
                        shortage=shortage.quantity,
                    )
                    for shortage in allocations[item.order_id].shortages
                ),
            )
            for item in snapshot.risks
        ),
    )
