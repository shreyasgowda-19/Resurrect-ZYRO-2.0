"""Bounded, read-only endpoint sampling against the configured demo Firestore."""

import argparse
import json
import math
import platform
import statistics
from collections import Counter
from time import perf_counter
from unittest.mock import patch

from fastapi.testclient import TestClient
from google.cloud.firestore_v1.document import DocumentReference
from google.cloud.firestore_v1.query import Query

from app import gemini_service
from app.auth import AuthenticatedUser, authenticated_user
from app.inventory.store import FirestoreInventoryStore
from app.main import app


def latency(samples: list[float]) -> dict:
    ordered = sorted(samples)
    return {
        "samples": len(samples),
        "median_ms": round(statistics.median(samples), 3),
        "p95_ms": round(ordered[math.ceil(len(samples) * 0.95) - 1], 3),
    }


def measure(samples: int, gemini_smoke: bool) -> dict:
    counts: Counter = Counter()
    document_get = DocumentReference.get
    query_stream = Query.stream

    def counted_get(reference, *args, **kwargs):
        counts["document_gets"] += 1
        snapshot = document_get(reference, *args, **kwargs)
        counts["documents_returned"] += snapshot.exists
        return snapshot

    def counted_stream(query, *args, **kwargs):
        counts["collection_queries"] += 1
        for snapshot in query_stream(query, *args, **kwargs):
            counts["documents_returned"] += 1
            yield snapshot

    def provider_unavailable(*args, **kwargs):
        raise gemini_service.GeminiUnavailable("Controlled benchmark provider failure.")

    actor = AuthenticatedUser(uid="t6-read-only-diagnostic", email=None, role="planner")
    state = FirestoreInventoryStore().read()
    body = {"question": "How was ORD-1042 recovered?", "order_id": "ORD-1042", "expected_version": state.version}
    stale = {**body, "expected_version": state.version + 1}
    requests = (
        ("state", "GET", "/state", None, 200),
        ("proposals", "GET", "/proposals", None, 200),
        ("ask_fallback", "POST", "/ai/ask", body, 200),
        ("briefing_fallback", "GET", "/ai/briefing", None, 200),
        ("ask_stale", "POST", "/ai/ask", stale, 409),
    )
    result = {
        "live_firestore_version": state.version,
        "environment": f"{platform.platform()}, Python {platform.python_version()}",
        "read_accounting": "SDK document gets, query streams and returned documents; not billed reads",
        "provider_for_timings": "simulated immediate provider unavailability",
    }
    with patch.dict(app.dependency_overrides, {authenticated_user: lambda: actor}), TestClient(app) as client:
        with (
            patch.object(DocumentReference, "get", counted_get),
            patch.object(Query, "stream", counted_stream),
            patch.object(gemini_service, "generate_structured", provider_unavailable),
        ):
            for label, method, path, payload, expected_status in requests:
                times = []
                reads = []
                for _ in range(samples):
                    counts.clear()
                    start = perf_counter()
                    response = client.request(method, path, json=payload)
                    times.append((perf_counter() - start) * 1000)
                    if response.status_code != expected_status:
                        raise RuntimeError(f"{label} returned HTTP {response.status_code}, expected {expected_status}")
                    reads.append(dict(counts))
                result[label] = {**latency(times), "http": expected_status, "reads_per_request": reads}

        config_available = all(gemini_service.configuration_presence())
        smoke = {"configured": config_available, "attempted": gemini_smoke and config_available}
        if smoke["attempted"]:
            start = perf_counter()
            response = client.post("/ai/ask", json=body)
            smoke.update(
                status=response.status_code,
                mode=response.json().get("mode"),
                elapsed_ms=round((perf_counter() - start) * 1000, 3),
            )
        result["gemini_smoke"] = smoke
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--gemini-smoke", action="store_true", help="Allow one genuine provider attempt if configured.")
    args = parser.parse_args()
    print(json.dumps(measure(args.samples, args.gemini_smoke), indent=2))


if __name__ == "__main__":
    main()
