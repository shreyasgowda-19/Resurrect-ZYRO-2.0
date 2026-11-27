from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException

from app.auth import AuthenticatedUser, authenticated_user
from app.inventory.event_api import StructuredRoute
from app.inventory.proposal_models import DecisionRequest, DecisionResponse, ProposalList, ProposalResponse
from app.inventory.proposal_store import FirestoreProposalStore, proposal_store
from app.inventory.recovery_models import SimulationRequest

router = APIRouter(route_class=StructuredRoute)
Actor = Annotated[AuthenticatedUser, Depends(authenticated_user)]
Store = Annotated[FirestoreProposalStore, Depends(proposal_store)]

RESPONSES = {
    401: {"description": "Missing or invalid Firebase ID token"},
    403: {"description": "Unauthorized role or prohibited self-approval"},
    404: {"description": "Unknown proposal or recommendation"},
    409: {"description": "Stale version or conflicting request"},
    422: {"description": "Invalid request"},
    503: {"description": "Required service unavailable"},
}


@router.post("/proposals", response_model=ProposalResponse, responses=RESPONSES)
def create_proposal(request: SimulationRequest, actor: Actor, store: Store) -> ProposalResponse:
    if actor.role != "planner":
        raise HTTPException(403, "Only planners can submit proposals.")
    return store.create_proposal(request, actor)


@router.get("/proposals", response_model=ProposalList, responses=RESPONSES)
def list_proposals(_actor: Actor, store: Store) -> ProposalList:
    return store.list_proposals()


@router.post("/proposals/{proposal_id}/decision", response_model=DecisionResponse, responses=RESPONSES)
def decide_proposal(proposal_id: str, request: DecisionRequest, actor: Actor, store: Store) -> DecisionResponse:
    if actor.role != "approver":
        raise HTTPException(403, "Only approvers can decide proposals.")
    return store.decide(proposal_id, request, actor)
