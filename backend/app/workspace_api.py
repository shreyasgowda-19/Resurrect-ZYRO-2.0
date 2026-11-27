from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Path

from app.auth import Role, verified_claims
from app.inventory.event_api import StructuredRoute
from app.inventory.events import EventError
from app.inventory.models import InventoryModel
from app.inventory.state import StatePayload, render_state
from app.workspace_store import FirestoreWorkspaceStore, WORKSPACE_ID, WorkspaceDenied, workspace_store

router = APIRouter(prefix="/workspaces", route_class=StructuredRoute)
WorkspaceId = Annotated[str, Path(pattern=WORKSPACE_ID)]
Identity = Annotated[dict, Depends(verified_claims)]
Store = Annotated[FirestoreWorkspaceStore, Depends(workspace_store)]

ERRORS = {
    401: {"description": "Missing or invalid Firebase ID token"},
    403: {"description": "Workspace unavailable to caller"},
    422: {"description": "Malformed workspace identifier"},
    503: {"description": "Authentication or workspace storage unavailable"},
}


class WorkspaceInfo(InventoryModel):
    workspace_id: str
    name: str
    role: Role
    data_mode: Literal["operational"] = "operational"


class WorkspaceState(StatePayload):
    workspace_id: str
    role: Role
    data_mode: Literal["operational"] = "operational"


def allowed_read(store: FirestoreWorkspaceStore, workspace_id: str, claims: dict):
    try:
        return store.read(workspace_id, claims["uid"])
    except WorkspaceDenied:
        raise EventError(403, "FORBIDDEN", "Workspace unavailable to this account.") from None


@router.get("/{workspace_id}", response_model=WorkspaceInfo, responses=ERRORS)
def get_workspace(workspace_id: WorkspaceId, claims: Identity, store: Store) -> WorkspaceInfo:
    record, role = allowed_read(store, workspace_id, claims)
    return WorkspaceInfo(workspace_id=workspace_id, name=record.name, role=role)


@router.get("/{workspace_id}/state", response_model=WorkspaceState, responses=ERRORS)
def get_workspace_state(workspace_id: WorkspaceId, claims: Identity, store: Store) -> WorkspaceState:
    record, role = allowed_read(store, workspace_id, claims)
    payload = render_state(record.inventory)
    return WorkspaceState(workspace_id=workspace_id, role=role, **payload.model_dump())
