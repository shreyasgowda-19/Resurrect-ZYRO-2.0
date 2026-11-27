from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth import AuthenticatedUser, authenticated_user
from app.inventory.event_api import StructuredRoute
from app.inventory.events import DemoState, EventError
from app.inventory.recovery import evaluate_candidates, simulate
from app.inventory.recovery_models import (
    RecommendationRequest, RecommendationResponse, SimulationRequest, SimulationResponse,
)
from app.inventory.store import FirestoreInventoryStore, inventory_store

router = APIRouter(route_class=StructuredRoute)
RESPONSES = {
    401: {"description": "Missing or invalid Firebase ID token"},
    403: {"description": "Unauthorized role"},
    404: {"description": "Order or recommendation not found"},
    409: {"description": "Stale snapshot version"},
    422: {"description": "Invalid request"},
    503: {"description": "Required service unavailable"},
}


def read_version(store: FirestoreInventoryStore, expected_version: int) -> DemoState:
    state = store.read()
    if state.version != expected_version:
        raise EventError(409, "STALE_VERSION", "Refresh the dashboard before requesting a new calculation.")
    return state


@router.post("/recommendations", response_model=RecommendationResponse, responses=RESPONSES)
def recommendations(
    request: RecommendationRequest,
    _user: Annotated[AuthenticatedUser, Depends(authenticated_user)],
    store: Annotated[FirestoreInventoryStore, Depends(inventory_store)],
) -> RecommendationResponse:
    state = read_version(store, request.expected_version)
    candidates = evaluate_candidates(state, request.order_id)
    return RecommendationResponse(
        order_id=request.order_id,
        version=state.version,
        recommendations=tuple(item.recommendation for item in candidates),
    )


@router.post("/simulate", response_model=SimulationResponse, responses=RESPONSES)
def simulate_recommendation(
    request: SimulationRequest,
    _user: Annotated[AuthenticatedUser, Depends(authenticated_user)],
    store: Annotated[FirestoreInventoryStore, Depends(inventory_store)],
) -> SimulationResponse:
    state = read_version(store, request.expected_version)
    return simulate(state, request.order_id, request.recommendation_id)
