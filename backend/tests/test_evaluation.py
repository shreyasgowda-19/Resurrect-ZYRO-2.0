import pytest

from app.inventory.events import EventError
from scripts.evaluate_manufacturing import evaluate
from scripts.evaluation_firestore import Collection
from test_proposals import workflow


def test_stale_ai_read_skips_all_proposal_queries(workflow, monkeypatch):
    _, store, _ = workflow

    def forbidden(*args, **kwargs):
        pytest.fail("Stale inventory version must be rejected before scheduling Firestore queries")

    monkeypatch.setattr(Collection, "stream", forbidden)
    with pytest.raises(EventError) as captured:
        store.read_with_proposals(expected_version=1)
    assert (captured.value.status, captured.value.code) == (409, "STALE_VERSION")


def test_manufacturing_evaluation_checks_all_scenarios():
    results = evaluate()
    assert len({case["scenario"] for case in results["scenarios"]}) == 10
    assert all(case["passed"] and case["actual"] == case["expected"] for case in results["scenarios"])
    assert results["impact"]["slack_improvement_days"] == 3
    assert results["impact"]["duplicate_purchase_orders"] == 0
