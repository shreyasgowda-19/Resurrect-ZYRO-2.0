from datetime import UTC, datetime

import pytest

from app.inventory.demo import demo_inventory
from app.inventory.events import DemoState, EventResult, apply_event
from app.inventory.store import StateUnavailable, inventory_store, replay_result
from app.main import app


class MemoryInventoryStore:
    def __init__(self):
        self.state = DemoState(version=1, facts=demo_inventory())
        self.records = {}
        self.fail = False

    def read(self):
        if self.fail:
            raise StateUnavailable("Mocked storage failure.")
        return self.state

    def submit(self, event, actor_uid):
        if event.event_id in self.records:
            return replay_result(self.records[event.event_id], event, actor_uid)
        updated, _ = apply_event(self.state, event, datetime(2026, 12, 1, tzinfo=UTC))
        if self.fail:
            raise StateUnavailable("Mocked commit failure.")
        self.records[event.event_id] = {
            "actor_uid": actor_uid, "request": event.model_dump(mode="json"), "version": updated.version,
        }
        self.state = updated
        return EventResult(event_id=event.event_id, status="applied", version=updated.version)


@pytest.fixture
def inventory_backend():
    store = MemoryInventoryStore()
    app.dependency_overrides[inventory_store] = lambda: store
    try:
        yield store
    finally:
        del app.dependency_overrides[inventory_store]
