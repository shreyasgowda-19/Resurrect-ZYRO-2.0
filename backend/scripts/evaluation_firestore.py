"""In-memory transaction adapter for isolated backend verification."""

from copy import deepcopy
from threading import Lock
from types import SimpleNamespace

from google.api_core.exceptions import AlreadyExists

ROOT = ("demo", "isolated")


class Document:
    def __init__(self, db, path):
        self.db = db
        self.path = path

    def get(self, transaction=None, **kwargs):
        return snapshot(self.db.records.get(self.path))

    def collection(self, name):
        return Collection(self.db, (*self.path, name))


def snapshot(value):
    return SimpleNamespace(exists=value is not None, to_dict=lambda: deepcopy(value))


class Collection:
    def __init__(self, db, path, order=None, maximum=None):
        self.db = db
        self.path = path
        self.order = order
        self.maximum = maximum

    def document(self, name):
        return Document(self.db, (*self.path, name))

    def order_by(self, field, direction):
        assert direction == "DESCENDING"
        return Collection(self.db, self.path, field, self.maximum)

    def limit(self, maximum):
        return Collection(self.db, self.path, self.order, maximum)

    def stream(self, **kwargs):
        rows = [
            (path[-1], value) for path, value in self.db.records.items()
            if path[:-1] == self.path
        ]
        if self.order:
            rows.sort(key=lambda item: (item[1][self.order], item[0]), reverse=True)
        return [snapshot(value) for _, value in rows[:self.maximum]]


class Transaction:
    def __init__(self, db):
        self.db = db
        self.pending = {}

    def set(self, reference, body):
        self.pending[reference.path] = body

    def create(self, reference, body):
        if reference.path in self.db.records or reference.path in self.pending:
            raise AlreadyExists("mock conflicting document")
        self.set(reference, body)


class MemoryFirestore:
    def __init__(self, state):
        self.records = {ROOT: state.model_dump(mode="json")}
        self.lock = Lock()

    def transaction(self, **kwargs):
        return Transaction(self)

    @staticmethod
    def transactional(function):
        def run(transaction):
            with transaction.db.lock:
                result = function(transaction)
                transaction.db.records.update(deepcopy(transaction.pending))
                return result
        return run
