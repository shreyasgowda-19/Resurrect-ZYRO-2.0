from datetime import UTC, datetime
import re

from google.cloud.firestore import transactional

from app.auth import AuthenticatedUser
from app.firebase_service import log_firebase_failure
from app.inventory.events import DemoState, EventError
from app.inventory.proposal_models import (
    AuditEntry, DecisionRequest, DecisionResponse, Proposal, ProposalList, ProposalResponse, PurchaseOrder,
)
from app.inventory.proposals import audit, make_proposal, plan_decision, proposal_id_for, stable_id, with_staleness
from app.inventory.recovery_models import SimulationRequest
from app.inventory.store import FIRESTORE_ERRORS, FirestoreInventoryStore, StateUnavailable

HISTORY_LIMIT = 20


def read_document(reference, transaction):
    return reference.get(transaction=transaction, retry=None, timeout=10)


def read_inventory(reference, transaction) -> DemoState:
    snapshot = read_document(reference, transaction)
    if not snapshot.exists:
        raise StateUnavailable("Demo inventory has not been initialized.")
    return DemoState.model_validate(snapshot.to_dict())


def write_audits(reference, transaction, entries: tuple[AuditEntry, ...]) -> None:
    collection = reference.collection("proposal_audit")
    for entry in entries:
        body = entry.model_dump(mode="json")
        body["timestamp"] = entry.timestamp
        transaction.create(collection.document(entry.audit_id), body)


class FirestoreProposalStore(FirestoreInventoryStore):
    def create_proposal(self, request: SimulationRequest, actor: AuthenticatedUser) -> ProposalResponse:
        timestamp = datetime.now(UTC)
        try:
            client, root = self._references()
            reference = root.collection("proposals").document(proposal_id_for(request))

            @transactional
            def create(transaction):
                state = read_inventory(root, transaction)
                existing = read_document(reference, transaction)
                if existing.exists:
                    proposal = Proposal.model_validate(existing.to_dict())
                    if proposal.created_by != actor.uid or (
                        proposal.order_id, proposal.recommendation_id, proposal.snapshot_version
                    ) != (request.order_id, request.recommendation_id, request.expected_version):
                        raise EventError(409, "PROPOSAL_CONFLICT", "This recommendation already has a proposal.")
                    return ProposalResponse(
                        status="duplicate", version=state.version, proposal=with_staleness(proposal, state.version),
                    )

                proposal = make_proposal(state, request, actor, timestamp)
                body = proposal.model_dump(mode="json")
                body["created_at"] = timestamp
                transaction.create(reference, body)
                write_audits(root, transaction, (audit(
                    proposal, "proposal_submitted", actor, timestamp, state.version,
                    f"Submitted {proposal.action_type} for {proposal.order_id}.",
                ),))
                return ProposalResponse(status="created", version=state.version, proposal=proposal)

            return create(client.transaction())
        except (*FIRESTORE_ERRORS, ValueError):
            raise StateUnavailable("Proposal storage is unavailable.") from None

    def decide(
        self, proposal_id: str, request: DecisionRequest, actor: AuthenticatedUser,
    ) -> DecisionResponse:
        timestamp = datetime.now(UTC)
        try:
            client, root = self._references()
            decision_ref = root.collection("proposal_decisions").document(stable_id("decision", request.decision_id))
            request_body = request.model_dump(mode="json")

            @transactional
            def commit(transaction):
                previous = read_document(decision_ref, transaction)
                if previous.exists:
                    body = previous.to_dict()
                    if (body["actor_uid"], body["proposal_id"], body["request"]) != (
                        actor.uid, proposal_id, request_body,
                    ):
                        raise EventError(409, "DECISION_ID_CONFLICT", "This decision ID already belongs to another request.")
                    result = DecisionResponse.model_validate(body["result"])
                    return result.model_copy(update={"status": "duplicate"})

                if not re.fullmatch(r"prop-[0-9a-f]{64}", proposal_id):
                    raise EventError(404, "NOT_FOUND", "Proposal not found.")
                proposal_ref = root.collection("proposals").document(proposal_id)
                proposal_snapshot = read_document(proposal_ref, transaction)
                if not proposal_snapshot.exists:
                    raise EventError(404, "NOT_FOUND", "Proposal not found.")
                proposal = Proposal.model_validate(proposal_snapshot.to_dict())
                if proposal.proposal_id != proposal_id:
                    raise EventError(409, "EVIDENCE_MISMATCH", "Stored proposal identifier does not match.")
                state = read_inventory(root, transaction)
                plan = plan_decision(state, proposal, request, actor, timestamp)
                result = plan.response

                if plan.updated_state is not None:
                    transaction.set(root, plan.updated_state.model_dump(mode="json"))
                if result.purchase_order is not None:
                    order = result.purchase_order
                    order_ref = root.collection("purchase_orders").document(order.purchase_order_id)
                    transaction.create(order_ref, {
                        "purchase_order": order.model_dump(mode="json"),
                        "supplier_commitment": "synthetic_demo",
                        "incoming_lot_id": f"hypothetical-{proposal.recommendation_id}",
                        "created_at": timestamp,
                    })
                proposal_body = result.proposal.model_dump(mode="json")
                proposal_body["created_at"] = result.proposal.created_at
                transaction.set(proposal_ref, proposal_body)
                transaction.create(decision_ref, {
                    "actor_uid": actor.uid,
                    "proposal_id": proposal_id,
                    "request": request_body,
                    "result": result.model_dump(mode="json"),
                })
                write_audits(root, transaction, plan.audits)
                return result

            return commit(client.transaction())
        except (*FIRESTORE_ERRORS, ValueError):
            raise StateUnavailable("Proposal storage is unavailable.") from None

    def list_proposals(self) -> ProposalList:
        return self.read_with_proposals()[1]

    def read_with_proposals(self) -> tuple[DemoState, ProposalList]:
        try:
            client, root = self._references()

            @transactional
            def read(transaction):
                state = read_inventory(root, transaction)
                proposals = [
                    Proposal.model_validate(document.to_dict())
                    for document in root.collection("proposals").stream(transaction=transaction, retry=None, timeout=10)
                ]
                proposals.sort(key=lambda item: (item.created_at, item.proposal_id), reverse=True)
                pending = [with_staleness(item, state.version) for item in proposals if item.status == "pending"]
                completed = [item for item in proposals if item.status != "pending"][:HISTORY_LIMIT]
                orders = root.collection("purchase_orders").order_by("created_at", direction="DESCENDING")
                audits = root.collection("proposal_audit").order_by("timestamp", direction="DESCENDING")
                return state, ProposalList(
                    version=state.version,
                    proposals=tuple(pending + completed),
                    purchase_orders=tuple(
                        PurchaseOrder.model_validate(item.to_dict()["purchase_order"])
                        for item in orders.limit(HISTORY_LIMIT).stream(transaction=transaction, retry=None, timeout=10)
                    ),
                    audit_logs=tuple(
                        AuditEntry.model_validate(item.to_dict())
                        for item in audits.limit(HISTORY_LIMIT).stream(transaction=transaction, retry=None, timeout=10)
                    ),
                )

            return read(client.transaction(read_only=True))
        except (*FIRESTORE_ERRORS, ValueError) as error:
            log_firebase_failure("read_proposals", error)
            raise StateUnavailable("Proposal storage is unavailable.") from None


def proposal_store() -> FirestoreProposalStore:
    return FirestoreProposalStore()
