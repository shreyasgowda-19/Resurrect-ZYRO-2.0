from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Path

from app.auth import Role, verified_claims
from app.inventory.event_api import StructuredRoute
from app.inventory.events import EventError
from app.inventory.models import InventoryModel
from app.inventory.state import StatePayload, render_state
from app.workspace_materials import MATERIAL_ID, MaterialCreate, MaterialMutationResult, MaterialPatch, WorkspaceMaterial
from app.workspace_store import (
    FirestoreWorkspaceStore, WORKSPACE_ID, WorkspaceDenied, operational_materials, workspace_store,
)

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
    materials: tuple[WorkspaceMaterial, ...]
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
    return WorkspaceState(
        workspace_id=workspace_id, role=role, materials=operational_materials(record, payload),
        **payload.model_dump(exclude={"materials"}),
    )

def write_material(store: FirestoreWorkspaceStore, claims: dict, workspace_id: str,
                   material_id: str, request: MaterialCreate | MaterialPatch) -> MaterialMutationResult:
    try:
        return store.save_material(workspace_id, claims["uid"], material_id, request)
    except WorkspaceDenied:
        raise EventError(403, "FORBIDDEN", "Active Planner membership is required.") from None


WRITE_ERRORS = {
    **ERRORS,
    404: {"description": "Material not found"},
    409: {"description": "Stale version, duplicate material or conflicting mutation ID"},
}


@router.post("/{workspace_id}/materials", response_model=MaterialMutationResult, responses=WRITE_ERRORS)
def create_material(workspace_id: WorkspaceId, claims: Identity, store: Store,
                    request: MaterialCreate) -> MaterialMutationResult:
    return write_material(store, claims, workspace_id, request.material_id, request)


@router.patch("/{workspace_id}/materials/{material_id}", response_model=MaterialMutationResult, responses=WRITE_ERRORS)
def edit_material(workspace_id: WorkspaceId, material_id: Annotated[str, Path(pattern=MATERIAL_ID)],
                  claims: Identity, store: Store, request: MaterialPatch) -> MaterialMutationResult:
    return write_material(store, claims, workspace_id, material_id, request)
