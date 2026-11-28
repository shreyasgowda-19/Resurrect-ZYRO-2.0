"""Operational storage. Demo repositories cannot be selected from this module."""

import re
from collections.abc import Mapping
from datetime import UTC, date, datetime
from uuid import uuid4

from google.cloud.firestore import transactional
from pydantic import Field

from app.auth import ROLES, Role
from app.firebase_service import firestore_client, log_firebase_failure
from app.inventory.events import DemoState, EventError
from app.inventory.models import Identifier, InventoryInput, InventoryModel, Material, Plant
from app.inventory.proposals import stable_id
from app.inventory.state import StatePayload, render_state
from app.inventory.store import FIRESTORE_ERRORS, StateUnavailable

from app.workspace_materials import MaterialCreate, MaterialExtra, MaterialMutationResult, MaterialPatch, WorkspaceMaterial

WORKSPACES = "zyro_workspaces"
WORKSPACE_ID = r"^[a-f0-9]{32}$"


class WorkspaceDenied(Exception):
    """A uniform permission failure for missing or unauthorized workspaces."""


class WorkspaceRecord(InventoryModel):
    name: Identifier
    inventory: DemoState
    material_metadata: dict[str, MaterialExtra] = Field(default_factory=dict)


def operational_materials(record: WorkspaceRecord, payload: StatePayload) -> tuple[WorkspaceMaterial, ...]:
    return tuple(
        WorkspaceMaterial(**item.model_dump(),
                          **record.material_metadata.get(item.material_id, MaterialExtra()).model_dump())
        for item in payload.materials
    )


def authorized_workspace(root, uid: str, transaction, *, planner_only: bool = False) -> tuple[WorkspaceRecord, Role]:
    member = root.collection("members").document(uid).get(transaction=transaction, retry=None, timeout=10)
    if not member.exists:
        raise WorkspaceDenied
    record = member.to_dict()
    role = record.get("role")
    if record.get("active") is not True or role not in ROLES or (planner_only and role != "planner"):
        raise WorkspaceDenied
    workspace = root.get(transaction=transaction, retry=None, timeout=10)
    if not workspace.exists:
        raise WorkspaceDenied
    return WorkspaceRecord.model_validate(workspace.to_dict()), role


def safe_uid(uid: str) -> bool:
    return (
        bool(uid) and len(uid) <= 128 and "/" not in uid
        and uid not in (".", "..") and not (uid.startswith("__") and uid.endswith("__"))
    )


class FirestoreWorkspaceStore:
    def read(self, workspace_id: str, uid: str) -> tuple[WorkspaceRecord, Role]:
        if not re.fullmatch(WORKSPACE_ID, workspace_id) or not safe_uid(uid):
            raise WorkspaceDenied
        try:
            client = firestore_client()
            root = client.collection(WORKSPACES).document(workspace_id)
            @transactional
            def authorized_read(transaction):
                return authorized_workspace(root, uid, transaction)

            return authorized_read(client.transaction(read_only=True))
        except (*FIRESTORE_ERRORS, ValueError) as error:
            log_firebase_failure("read_operational_workspace", error)
            raise StateUnavailable("Operational workspace storage is unavailable.") from None

    def save_material(
        self, workspace_id: str, uid: str, material_id: str,
        request: MaterialCreate | MaterialPatch,
    ) -> MaterialMutationResult:
        if not re.fullmatch(WORKSPACE_ID, workspace_id) or not safe_uid(uid):
            raise WorkspaceDenied
        material_id = material_id.upper()
        creating = isinstance(request, MaterialCreate)
        operation = "material_created" if creating else "material_updated"
        body = request.model_dump(mode="json", exclude_unset=not creating)
        key = stable_id("material-mutation", request.mutation_id)
        timestamp = datetime.now(UTC).isoformat()
        try:
            client = firestore_client()
            root = client.collection(WORKSPACES).document(workspace_id)
            mutation = root.collection("material_mutations").document(key)
            audit = root.collection("material_audit").document(key)

            @transactional
            def commit(transaction):
                record, role = authorized_workspace(root, uid, transaction, planner_only=True)
                prior = mutation.get(transaction=transaction, retry=None, timeout=10)
                if prior.exists:
                    saved = prior.to_dict()
                    if (saved["actor_uid"], saved["action"], saved["material_id"], saved["request"]) != (
                        uid, operation, material_id, body,
                    ):
                        raise EventError(409, "MUTATION_ID_CONFLICT", "This mutation ID already belongs to another request.")
                    return MaterialMutationResult.model_validate(saved["result"]).model_copy(update={"status": "duplicate"})
                if request.expected_version != record.inventory.version:
                    raise EventError(409, "STALE_VERSION", "Refresh the workspace and try again.")

                facts = record.inventory.facts
                existing = next((item for item in facts.materials if item.material_id.upper() == material_id), None)
                metadata = dict(record.material_metadata)
                if creating:
                    if existing is not None:
                        raise EventError(409, "DUPLICATE_MATERIAL", "This material ID already exists.")
                    item = Material(material_id=material_id, name=request.name, unit=request.unit, on_hand=0)
                    extra = MaterialExtra(reorder_threshold=request.reorder_threshold, description=request.description)
                    materials = (*facts.materials, item)
                    before = None
                else:
                    if existing is None:
                        raise EventError(404, "NOT_FOUND", "Material not found.")
                    extra = metadata.get(existing.material_id, MaterialExtra())
                    before = {"name": existing.name, "unit": existing.unit, **extra.model_dump(mode="json")}
                    item = existing.model_copy(update={k: body[k] for k in ("name", "unit") if k in body})
                    extra = extra.model_copy(update={k: body[k] for k in ("reorder_threshold", "description") if k in body})
                    materials = tuple(item if current.material_id == existing.material_id else current for current in facts.materials)

                metadata[item.material_id] = extra
                updated = record.model_copy(update={
                    "material_metadata": metadata,
                    "inventory": record.inventory.model_copy(update={
                        "version": record.inventory.version + 1,
                        "facts": facts.model_copy(update={"materials": materials}),
                    }),
                })
                response_material = next(
                    entry for entry in operational_materials(updated, render_state(updated.inventory))
                    if entry.material_id == item.material_id
                )
                result = MaterialMutationResult(
                    status="applied", workspace_id=workspace_id,
                    version=updated.inventory.version, material=response_material,
                )
                transaction.set(root, updated.model_dump(mode="json"))
                transaction.create(mutation, {
                    "actor_uid": uid, "action": operation, "material_id": material_id,
                    "request": body, "result": result.model_dump(mode="json"),
                })
                transaction.create(audit, {
                    "action": operation, "actor_uid": uid, "actor_role": role,
                    "material_id": item.material_id, "mutation_id": request.mutation_id,
                    "version": result.version, "recorded_at": timestamp, "before": before,
                    "after": {"name": item.name, "unit": item.unit, **extra.model_dump(mode="json")},
                })
                return result

            return commit(client.transaction())
        except (*FIRESTORE_ERRORS, ValueError) as error:
            log_firebase_failure("mutate_operational_material", error)
            raise StateUnavailable("Operational workspace storage is unavailable.") from None

    def initialize(self, name: str, as_of_date: date, members: Mapping[str, Role]) -> str:
        """Trusted administrator-only provisioning, never exposed as an HTTP handler."""
        roles = dict(members)
        if not roles or any(not safe_uid(uid) or role not in ROLES for uid, role in roles.items()):
            raise ValueError("Provide at least one verified Firebase UID and valid workspace role.")
        workspace_id = uuid4().hex
        workspace = WorkspaceRecord(
            name=name,
            inventory=DemoState(
                version=1,
                facts=InventoryInput(
                    as_of_date=as_of_date,
                    plant=Plant(plant_id=workspace_id, name=name),
                    materials=(), suppliers=(), incoming_lots=(), orders=(),
                ),
            ),
        )
        try:
            client = firestore_client()
            root = client.collection(WORKSPACES).document(workspace_id)

            @transactional
            def create(transaction):
                transaction.create(root, workspace.model_dump(mode="json"))
                for uid, role in roles.items():
                    transaction.create(root.collection("members").document(uid), {"role": role, "active": True})

            create(client.transaction())
        except (*FIRESTORE_ERRORS, ValueError) as error:
            log_firebase_failure("initialize_operational_workspace", error)
            raise StateUnavailable("Operational workspace could not be provisioned.") from None
        return workspace_id


def workspace_store() -> FirestoreWorkspaceStore:
    return FirestoreWorkspaceStore()
