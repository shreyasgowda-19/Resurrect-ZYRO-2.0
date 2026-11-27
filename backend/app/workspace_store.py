"""Operational storage. Demo repositories cannot be selected from this module."""

import re
from collections.abc import Mapping
from datetime import date
from uuid import uuid4

from google.cloud.firestore import transactional

from app.auth import ROLES, Role
from app.firebase_service import firestore_client, log_firebase_failure
from app.inventory.events import DemoState
from app.inventory.models import Identifier, InventoryInput, InventoryModel, Plant
from app.inventory.store import FIRESTORE_ERRORS, StateUnavailable

WORKSPACES = "zyro_workspaces"
WORKSPACE_ID = r"^[a-f0-9]{32}$"


class WorkspaceDenied(Exception):
    """A uniform permission failure for missing or unauthorized workspaces."""


class WorkspaceRecord(InventoryModel):
    name: Identifier
    inventory: DemoState


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
            member = root.collection("members").document(uid)

            @transactional
            def authorized_read(transaction):
                membership = member.get(transaction=transaction, retry=None, timeout=10)
                if not membership.exists:
                    raise WorkspaceDenied
                record = membership.to_dict()
                role = record.get("role")
                if record.get("active") is not True or role not in ROLES:
                    raise WorkspaceDenied
                workspace = root.get(transaction=transaction, retry=None, timeout=10)
                if not workspace.exists:
                    raise WorkspaceDenied
                return WorkspaceRecord.model_validate(workspace.to_dict()), role

            return authorized_read(client.transaction(read_only=True))
        except (*FIRESTORE_ERRORS, ValueError) as error:
            log_firebase_failure("read_operational_workspace", error)
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
