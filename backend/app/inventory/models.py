import re
from collections.abc import Iterable
from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field, model_validator


def validate_calendar_date(value: object) -> object:
    if type(value) is date:
        return value
    if isinstance(value, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        return value
    raise ValueError("Expected a calendar date in YYYY-MM-DD format")


def validate_timestamp(value: datetime) -> datetime:
    if value.utcoffset() is None:
        raise ValueError("Creation timestamps require a timezone")
    return value


CalendarDate = Annotated[date, BeforeValidator(validate_calendar_date)]
Timestamp = Annotated[datetime, AfterValidator(validate_timestamp)]
Quantity = Annotated[int, Field(strict=True, ge=0)]
PositiveQuantity = Annotated[int, Field(strict=True, gt=0)]
Identifier = Annotated[str, Field(min_length=1)]
Priority = Literal["high", "medium", "low"]
Risk = Literal["delayed", "critical", "at_risk", "on_track"]


class InventoryModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, str_strip_whitespace=True)


class Plant(InventoryModel):
    plant_id: Identifier
    name: Identifier


class Material(InventoryModel):
    material_id: Identifier
    name: Identifier
    unit: Identifier
    on_hand: Quantity


class Supplier(InventoryModel):
    supplier_id: Identifier
    name: Identifier


class SupplyLot(InventoryModel):
    lot_id: Identifier
    material_id: Identifier
    supplier_id: Identifier
    quantity: PositiveQuantity
    expected_arrival: CalendarDate
    status: Literal["confirmed", "unconfirmed", "received", "cancelled"]


class MaterialRequirement(InventoryModel):
    material_id: Identifier
    quantity: PositiveQuantity


class CustomerOrder(InventoryModel):
    order_id: Identifier
    customer_name: Identifier
    priority: Priority
    crd: CalendarDate
    created_at: Timestamp
    production_days: Quantity
    transit_days: Quantity
    requirements: Annotated[tuple[MaterialRequirement, ...], Field(min_length=1)]

    @model_validator(mode="after")
    def unique_requirements(self):
        unique_ids(item.material_id for item in self.requirements)
        return self


def unique_ids(identifiers: Iterable[str]) -> set[str]:
    values = tuple(identifiers)
    unique = set(values)
    if len(unique) != len(values):
        raise ValueError("Duplicate identifier")
    return unique


class InventoryInput(InventoryModel):
    as_of_date: CalendarDate
    plant: Plant
    materials: tuple[Material, ...]
    suppliers: tuple[Supplier, ...]
    incoming_lots: tuple[SupplyLot, ...]
    orders: tuple[CustomerOrder, ...]

    @model_validator(mode="after")
    def validate_references(self):
        materials = unique_ids(item.material_id for item in self.materials)
        suppliers = unique_ids(item.supplier_id for item in self.suppliers)
        unique_ids(item.order_id for item in self.orders)
        unique_ids(item.lot_id for item in self.incoming_lots)
        for lot in self.incoming_lots:
            if lot.material_id not in materials or lot.supplier_id not in suppliers:
                raise ValueError("Unknown material or supplier in supply lot")
        for order in self.orders:
            if any(item.material_id not in materials for item in order.requirements):
                raise ValueError("Unknown order material")
        return self


class Reservation(InventoryModel):
    material_id: Identifier
    quantity: PositiveQuantity
    available_on: CalendarDate
    lot_id: Identifier | None


class Shortage(InventoryModel):
    material_id: Identifier
    required: PositiveQuantity
    available: Quantity

    @property
    def quantity(self) -> int:
        return self.required - self.available


class AllocationResult(InventoryModel):
    order_id: Identifier
    reservations: tuple[Reservation, ...]
    shortages: tuple[Shortage, ...]


class RiskResult(InventoryModel):
    order_id: Identifier
    material_ready_date: CalendarDate | None
    projected_ship_date: CalendarDate | None
    projected_delivery_date: CalendarDate | None
    slack_days: int | None
    risk: Risk


class MaterialAvailability(InventoryModel):
    material_id: Identifier
    on_hand: Quantity
    eligible_incoming: Quantity
    allocated: Quantity
    net_availability: Quantity


class InventorySnapshot(InventoryInput):
    data_mode: Literal["demo"] = "demo"
    version: Literal[1] = 1
    availability: tuple[MaterialAvailability, ...]
    allocations: tuple[AllocationResult, ...]
    risks: tuple[RiskResult, ...]
