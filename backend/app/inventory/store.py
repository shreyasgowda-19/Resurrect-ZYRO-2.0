from datetime import UTC, datetime
from hashlib import sha256

from google.api_core.exceptions import AlreadyExists, GoogleAPIError
from google.auth.exceptions import GoogleAuthError
from google.cloud.firestore import transactional
from pydantic import ValidationError

from app.firebase_service import FirebaseUnavailable, firestore_client
from app.inventory.demo import demo_inventory
from app.inventory.events import DemoState, Event, EventError, EventResult, apply_event

COLLECTION = "zyro_demo_inventory"
DOCUMENT = "current"
FIRESTORE_ERRORS = (FirebaseUnavailable, GoogleAPIError, GoogleAuthError, OSError)


class StateUnavailable(RuntimeError):
    pass


def event_document_id(event_id: str) -> str:
    return sha256(event_id.encode("utf-8")).hexdigest()


def replay_result(record: dict, event: Event, actor_uid: str) -> EventResult:
    if record["actor_uid"] != actor_uid or record["request"] != event.model_dump(mode="json"):
        raise EventError(409, "EVENT_ID_CONFLICT", "Event ID is already associated with a different submission.")
    return EventResult(event_id=event.event_id, status="duplicate", version=record["version"])


class FirestoreInventoryStore:
    def __init__(self, document_id: str = DOCUMENT):
        self.document_id = document_id

    def _references(self):
        client = firestore_client()
        return client, client.collection(COLLECTION).document(self.document_id)

    def initialize(self) -> bool:
        try:
            _, reference = self._references()
            initial = DemoState(version=1, facts=demo_inventory())
            reference.create(initial.model_dump(mode="json"), retry=None, timeout=10)
        except AlreadyExists:
            return False
        except FIRESTORE_ERRORS:
            raise StateUnavailable("Demo inventory could not be initialized.") from None
        return True

    def read(self) -> DemoState:
        try:
            _, reference = self._references()
            snapshot = reference.get(retry=None, timeout=10)
            if not snapshot.exists:
                raise StateUnavailable("Demo inventory has not been initialized.")
            return DemoState.model_validate(snapshot.to_dict())
        except (*FIRESTORE_ERRORS, ValidationError):
            raise StateUnavailable("Demo inventory is unavailable.") from None

    def submit(self, event: Event, actor_uid: str) -> EventResult:
        recorded_at = datetime.now(UTC)
        try:
            client, reference = self._references()
            event_ref = reference.collection("events").document(event_document_id(event.event_id))

            @transactional
            def commit(transaction):
                prior_event = event_ref.get(transaction=transaction, retry=None, timeout=10)
                if prior_event.exists:
                    return replay_result(prior_event.to_dict(), event, actor_uid)

                current = reference.get(transaction=transaction, retry=None, timeout=10)
                if not current.exists:
                    raise StateUnavailable("Demo inventory has not been initialized.")
                state = DemoState.model_validate(current.to_dict())
                try:
                    updated, alerts = apply_event(state, event, recorded_at)
                except (OverflowError, ValidationError):
                    raise EventError(422, "INVALID_OPERATION", "Event exceeds supported inventory or date limits.") from None

                transaction.set(reference, updated.model_dump(mode="json"))
                transaction.create(event_ref, {
                    **updated.recent_events[0].model_dump(mode="json"),
                    "actor_uid": actor_uid,
                    "request": event.model_dump(mode="json"),
                })
                for alert in alerts:
                    alert_ref = reference.collection("alerts").document(alert.alert_id)
                    transaction.create(alert_ref, alert.model_dump(mode="json"))
                return EventResult(event_id=event.event_id, status="applied", version=updated.version)

            return commit(client.transaction())
        except (*FIRESTORE_ERRORS, ValueError):
            raise StateUnavailable("Demo inventory is unavailable.") from None


def inventory_store() -> FirestoreInventoryStore:
    return FirestoreInventoryStore()
