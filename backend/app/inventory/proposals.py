"""Deterministic proposal and approval rules, independent of persistence."""

import json
from dataclasses import dataclass
from datetime import datetime
from hashlib import sha256

from pydantic import ValidationError

from app.auth import AuthenticatedUser
from app.inventory.engine import calculate_inventory
from app.inventory.events import DemoState, EventError
from app.inventory.proposal_models import AuditAction, AuditEntry, DecisionRequest, DecisionResponse, Proposal, PurchaseOrder
from app.inventory.recovery import RecoveryAction, hypothetical_facts, resolve_candidate, simulate_candidate
from app.inventory.recovery_models import SimulationRequest


def stable_id(prefix: str, *values: str | int) -> str:
    encoded = json.dumps(values, separators=(",", ":")).encode("utf-8")
    return f"{prefix}-{sha256(encoded).hexdigest()}"


def proposal_id_for(request: SimulationRequest) -> str:
    return stable_id("prop", request.expected_version, request.order_id, request.recommendation_id)


def check_version(state: DemoState, expected_version: int) -> None:
    if state.version != expected_version:
        raise EventError(409, "STALE_VERSION", "Refresh the dashboard before submitting this request.")


def with_staleness(proposal: Proposal, version: int) -> Proposal:
    stale = proposal.status == "pending" and proposal.snapshot_version != version
    return proposal.model_copy(update={"is_stale": stale})


def make_proposal(
    state: DemoState, request: SimulationRequest, actor: AuthenticatedUser, timestamp: datetime
) -> Proposal:
    check_version(state, request.expected_version)
    candidate = resolve_candidate(state, request.order_id, request.recommendation_id)
    return Proposal(
        proposal_id=proposal_id_for(request),
        order_id=request.order_id,
        recommendation_id=request.recommendation_id,
        action_type=candidate.recommendation.action_type,
        snapshot_version=state.version,
        created_by=actor.uid,
        created_at=timestamp,
        recommendation=candidate.recommendation,
        simulation=simulate_candidate(state, request.order_id, candidate),
    )


def audit(
    proposal: Proposal, action: AuditAction, actor: AuthenticatedUser,
    timestamp: datetime, version: int, summary: str,
) -> AuditEntry:
    return AuditEntry(
        audit_id=stable_id("audit", proposal.proposal_id, action),
        action=action,
        actor_uid=actor.uid,
        actor_role=actor.role,
        proposal_id=proposal.proposal_id,
        timestamp=timestamp,
        version=version,
        summary=summary,
    )


@dataclass(frozen=True)
class DecisionPlan:
    response: DecisionResponse
    updated_state: DemoState | None
    audits: tuple[AuditEntry, ...]


def plan_decision(
    state: DemoState, proposal: Proposal, request: DecisionRequest,
    actor: AuthenticatedUser, timestamp: datetime,
) -> DecisionPlan:
    if proposal.status != "pending":
        raise EventError(409, "PROPOSAL_DECIDED", "This proposal already has a decision.")
    if request.decision == "approve" and proposal.created_by == actor.uid:
        raise EventError(403, "SELF_APPROVAL", "The proposal creator cannot approve this proposal.")
    check_version(state, request.expected_version)

    updated_state = None
    purchase_order = None
    execution_status = "not_executed"
    if request.decision == "approve":
        check_version(state, proposal.snapshot_version)
        original_request = SimulationRequest(
            order_id=proposal.order_id,
            recommendation_id=proposal.recommendation_id,
            expected_version=proposal.snapshot_version,
        )
        try:
            canonical = make_proposal(state, original_request, actor, timestamp)
        except EventError as error:
            if error.status != 404:
                raise
            raise EventError(409, "EVIDENCE_MISMATCH", "The original recommendation is no longer valid.") from None

        if (
            proposal.proposal_id != canonical.proposal_id
            or proposal.action_type != canonical.action_type
            or proposal.recommendation != canonical.recommendation
            or proposal.simulation != canonical.simulation
        ):
            raise EventError(409, "EVIDENCE_MISMATCH", "Stored proposal evidence does not match the current calculation.")

        recommendation = canonical.recommendation
        if recommendation.action_type == "alternate_supplier_po":
            action = RecoveryAction(
                recommendation.action_type, recommendation.material_id, recommendation.supplier_id,
                recommendation.lot_id, recommendation.quantity, recommendation.proposed_eta,
            )
            try:
                # Reuse the simulated lot ID so allocation tie breaks match the reviewed evidence.
                facts = hypothetical_facts(state.facts, action, recommendation.recommendation_id)
                calculate_inventory(facts)
                updated_state = DemoState.model_validate({
                    **state.model_dump(), "facts": facts, "version": state.version + 1,
                })
            except (ValidationError, OverflowError):
                raise EventError(422, "INVALID_OPERATION", "The demo supply cannot be added to inventory.") from None
            purchase_order = PurchaseOrder(
                purchase_order_id=stable_id("demo-po", proposal.proposal_id),
                proposal_id=proposal.proposal_id,
                order_id=proposal.order_id,
                supplier_id=recommendation.supplier_id,
                material_id=recommendation.material_id,
                quantity=recommendation.quantity,
                expected_delivery_date=recommendation.proposed_eta,
                estimated_incremental_cost=recommendation.estimated_incremental_cost,
                currency=recommendation.currency,
                created_by=actor.uid,
                created_at=timestamp,
            )
            execution_status = "demo_po_created"
        else:
            execution_status = "awaiting_supplier_confirmation"

    version = updated_state.version if updated_state else state.version
    approved = request.decision == "approve"
    decided = proposal.model_copy(update={
        "status": "approved" if approved else "rejected",
        "is_stale": False,
        "decided_by": actor.uid,
        "decided_at": timestamp,
        "decision_reason": request.reason,
        "purchase_order_id": purchase_order.purchase_order_id if purchase_order else None,
        "execution_status": execution_status,
    })
    entries = [audit(
        decided, "proposal_approved" if approved else "proposal_rejected",
        actor, timestamp, version, request.reason,
    )]
    if purchase_order:
        entries.append(audit(
            decided, "purchase_order_created", actor, timestamp, version,
            f"Created demo PO {purchase_order.purchase_order_id}; supplier commitment is simulated.",
        ))
    elif approved:
        entries.append(audit(
            decided, "expedite_authorized", actor, timestamp, version,
            f"Authorized expedite request for lot {decided.recommendation.lot_id}; awaiting supplier confirmation.",
        ))

    return DecisionPlan(
        DecisionResponse(status="applied", version=version, proposal=decided, purchase_order=purchase_order),
        updated_state,
        tuple(entries),
    )
