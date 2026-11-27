from datetime import date
from typing import Literal

from app.inventory.models import Identifier, InventoryModel, PositiveQuantity, Risk

ActionType = Literal["expedite_existing_lot", "alternate_supplier_po"]


class RecommendationRequest(InventoryModel):
    order_id: Identifier
    expected_version: PositiveQuantity


class SimulationRequest(RecommendationRequest):
    recommendation_id: Identifier


class Recommendation(InventoryModel):
    recommendation_id: str
    action_type: ActionType
    title: str
    explanation: str
    material_id: str
    supplier_id: str
    lot_id: str | None
    quantity: PositiveQuantity
    proposed_eta: date
    estimated_incremental_cost: float | None = None
    currency: str | None = None
    assumptions: tuple[str, ...]
    evidence: tuple[str, ...]


class RecommendationResponse(InventoryModel):
    order_id: str
    version: PositiveQuantity
    data_mode: Literal["demo"] = "demo"
    recommendations: tuple[Recommendation, ...]


class OrderOutcome(InventoryModel):
    projected_ship_date: date | None
    projected_delivery_date: date | None
    slack_days: int | None
    risk: Risk


class AffectedOrder(InventoryModel):
    order_id: str
    before: OrderOutcome
    after: OrderOutcome


class SimulationResponse(InventoryModel):
    order_id: str
    recommendation_id: str
    version: PositiveQuantity
    hypothetical: Literal[True] = True
    before: OrderOutcome
    after: OrderOutcome
    affected_orders: tuple[AffectedOrder, ...]
    estimated_incremental_cost: float | None
    currency: str | None
    assumptions: tuple[str, ...]
    warnings: tuple[str, ...]
