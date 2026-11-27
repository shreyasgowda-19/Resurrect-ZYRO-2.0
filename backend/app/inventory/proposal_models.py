from datetime import date
from typing import Annotated, Literal

from pydantic import Field, model_validator

from app.inventory.models import Identifier, InventoryModel, PositiveQuantity, Timestamp
from app.inventory.recovery_models import ActionType, Recommendation, SimulationResponse

AuditAction = Literal[
    "proposal_submitted", "proposal_approved", "proposal_rejected",
    "purchase_order_created", "expedite_authorized",
]


class DecisionRequest(InventoryModel):
    decision_id: Annotated[str, Field(min_length=1, max_length=256)]
    decision: Literal["approve", "reject"]
    expected_version: PositiveQuantity
    reason: Annotated[str, Field(min_length=1, max_length=2000)]
    acknowledge_demo_assumptions: Annotated[bool, Field(strict=True)]

    @model_validator(mode="after")
    def check_acknowledgment(self):
        if self.decision == "approve" and not self.acknowledge_demo_assumptions:
            raise ValueError("Approval requires acknowledgment of demo assumptions")
        return self


class Proposal(InventoryModel):
    proposal_id: Identifier
    order_id: Identifier
    recommendation_id: Identifier
    action_type: ActionType
    snapshot_version: PositiveQuantity
    status: Literal["pending", "approved", "rejected"] = "pending"
    is_stale: bool = False
    created_by: Identifier
    created_at: Timestamp
    recommendation: Recommendation
    simulation: SimulationResponse
    decided_by: str | None = None
    decided_at: Timestamp | None = None
    decision_reason: str | None = None
    purchase_order_id: str | None = None
    execution_status: Literal[
        "not_executed", "demo_po_created", "awaiting_supplier_confirmation",
    ] = "not_executed"


class PurchaseOrder(InventoryModel):
    purchase_order_id: Identifier
    proposal_id: Identifier
    order_id: Identifier
    supplier_id: Identifier
    material_id: Identifier
    quantity: PositiveQuantity
    expected_delivery_date: date
    estimated_incremental_cost: float | None
    currency: str | None
    status: Literal["demo_created"] = "demo_created"
    created_by: Identifier
    created_at: Timestamp


class AuditEntry(InventoryModel):
    audit_id: Identifier
    action: AuditAction
    actor_uid: Identifier
    actor_role: Literal["planner", "approver"]
    proposal_id: Identifier
    timestamp: Timestamp
    version: PositiveQuantity
    summary: str


class ProposalResponse(InventoryModel):
    status: Literal["created", "duplicate"]
    version: PositiveQuantity
    proposal: Proposal


class DecisionResponse(InventoryModel):
    status: Literal["applied", "duplicate"]
    version: PositiveQuantity
    proposal: Proposal
    purchase_order: PurchaseOrder | None


class ProposalList(InventoryModel):
    version: PositiveQuantity
    proposals: tuple[Proposal, ...]
    purchase_orders: tuple[PurchaseOrder, ...]
    audit_logs: tuple[AuditEntry, ...]
