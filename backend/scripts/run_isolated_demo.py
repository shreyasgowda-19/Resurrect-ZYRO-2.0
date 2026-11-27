"""Run a named, isolated judges' demo using the existing Firebase-authenticated API."""

import argparse
import re

import uvicorn

from app.inventory.proposal_store import FirestoreProposalStore, proposal_store
from app.inventory.store import FirestoreInventoryStore, StateUnavailable, inventory_store
from app.main import app


def isolated_document(name: str) -> str:
    if name == "current" or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?", name):
        raise argparse.ArgumentTypeError("Use a new namespace of 1-40 lowercase letters, digits or hyphens.")
    return f"t7-demo-{name}"


def serve(document_id: str, port: int) -> None:
    inventory = FirestoreInventoryStore(document_id)
    proposals = FirestoreProposalStore(document_id)
    state = inventory.read()
    print(f"Serving isolated demo {document_id} at version {state.version} on port {port}.", flush=True)
    original = app.dependency_overrides
    app.dependency_overrides = {inventory_store: lambda: inventory, proposal_store: lambda: proposals}
    try:
        uvicorn.run(app, host="127.0.0.1", port=port)
    finally:
        app.dependency_overrides = original


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    create = actions.add_parser("initialize", help="Create a new isolated demo at version 1.")
    create.add_argument("document_id", metavar="namespace", type=isolated_document)
    create.add_argument("--confirm-create", action="store_true", required=True,
                        help="Confirm human approval to create this isolated Firestore document.")
    start = actions.add_parser("serve", help="Serve an already initialized demo on localhost.")
    start.add_argument("document_id", metavar="namespace", type=isolated_document)
    start.add_argument("--port", type=int, default=8001)

    args = parser.parse_args(argv)
    try:
        if args.action == "serve":
            if not 1 <= args.port <= 65535:
                start.error("port must be between 1 and 65535")
            serve(args.document_id, args.port)
        else:
            created = FirestoreInventoryStore(args.document_id).initialize()
            if not created:
                print(f"Isolated demo {args.document_id} already exists. Use a new namespace for a fresh run.")
                return 1
            print(f"Created isolated demo {args.document_id} at version 1.")
    except StateUnavailable as error:
        print(f"Isolated demo {args.document_id}: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
