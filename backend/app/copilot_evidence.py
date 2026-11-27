import re
from dataclasses import dataclass

from app.auth import Role
from app.copilot_models import Evidence, Focus, Source
from app.inventory.engine import calculate_inventory
from app.inventory.events import DemoState, EventError, RISK_SEVERITY
from app.inventory.proposal_models import ProposalList
from app.inventory.recovery import evaluate_candidates

CONTEXT_LIMIT = 24
# Only these manufacturing terms are sent from a question to Gemini.
QUESTION_TERMS = frozenset("""
why which what how when where is was were are has have had before after now current previously latest
order orders risk risks critical delayed overdue attention immediate urgent on track shortage shortages
material materials copper inventory stock incoming supplier suppliers lot lots eta delivery delay
delays recovered recovery recover compare strategies options expedite alternative recommendation
recommendations simulate simulation hypothetical procurement approval approve approvals pending
proposal proposals stale purchase po cost costs price event events change changed happened briefing audit
""".split())
ORDER_PATTERN = re.compile(r"\bORD-[A-Z0-9]+(?:-[A-Z0-9]+)*\b", re.IGNORECASE)


@dataclass(frozen=True)
class Fact:
    source_type: Source
    source_id: str
    summary: str
    focus: Focus
    order_id: str | None = None
    severity: str = "info"
    variant: str | None = None


def question_terms(question: str) -> tuple[str, ...]:
    return tuple(token for token in re.findall(r"[a-z]+", question.lower()) if token in QUESTION_TERMS)[:40]


def question_focus(terms: tuple[str, ...], order_id: str | None) -> Focus:
    words = set(terms)
    if ("was" in words and words & {"risk", "critical", "delayed"}) or words & {"previously", "before", "event", "events", "latest", "happened", "history"}:
        return "history"
    if words & {"recovered", "recovery", "recover", "compare", "strategies", "recommendation",
                "recommendations", "simulate", "simulation", "expedite", "alternative"}:
        return "recovery"
    if words & {"proposal", "proposals", "purchase", "procurement", "approval", "approve", "po", "audit", "cost", "costs", "price"}:
        return "procurement"
    if words & {"shortage", "shortages", "material", "materials"}:
        return "shortages"
    return "current" if order_id else "overview"


def resolve_order(state: DemoState, question: str, order_id: str | None) -> str | None:
    if order_id is None:
        match = ORDER_PATTERN.search(question)
        order_id = match.group().upper() if match else None
    if order_id is not None and not any(order.order_id == order_id for order in state.facts.orders):
        raise EventError(404, "NOT_FOUND", "Order not found.")
    return order_id


def facts_for(
    state: DemoState, approvals: ProposalList, role: Role, focus: Focus, order_id: str | None,
    *, briefing: bool = False, historical_only: bool = False,
) -> tuple[Fact, ...]:
    snapshot = calculate_inventory(state.facts)
    orders = {item.order_id: item for item in snapshot.orders}
    allocations = {item.order_id: item for item in snapshot.allocations}
    risks = sorted(snapshot.risks, key=lambda item: -RISK_SEVERITY[item.risk])
    relevant = [item for item in risks if order_id is None or item.order_id == order_id]
    active = [item for item in relevant if item.risk != "on_track"]
    current, shortages, suppliers, history, recovery, procurement = [], [], [], [], [], []
    for result in relevant:
        order = orders[result.order_id]
        if order_id or result.risk != "on_track":
            delivery = (
                f"Projected delivery {result.projected_delivery_date}; slack {result.slack_days} days."
                if result.projected_delivery_date else "A projected delivery date is unavailable."
            )
            severity = "critical" if result.risk in ("critical", "delayed") else "warning" if result.risk == "at_risk" else "info"
            current.append(Fact(
                "order", order.order_id,
                f"Current: {order.order_id} is {result.risk}; requested delivery {order.crd}. {delivery}",
                "current", order.order_id, severity,
            ))
        for item in allocations[order.order_id].shortages:
            shortages.append(Fact(
                "inventory", item.material_id,
                f"Current shortage for {order.order_id}: {item.material_id} needs {item.required}, "
                f"has {item.available} available at allocation, and is short {item.quantity}.",
                "shortages", order.order_id, "critical",
            ))

    materials = set() if order_id is None else {item.material_id for item in orders[order_id].requirements}
    for lot in snapshot.incoming_lots:
        if lot.status != "confirmed" or (materials and lot.material_id not in materials):
            continue
        overdue = lot.expected_arrival < snapshot.as_of_date
        if overdue or order_id or focus == "history":
            suppliers.append(Fact(
                "supplier", lot.supplier_id,
                f"Current: {lot.lot_id} from {lot.supplier_id} has {lot.quantity} outstanding units of "
                f"{lot.material_id}, ETA {lot.expected_arrival}."
                + (" The lot is overdue and excluded from available supply." if overdue else
                   " The demo lot's recorded ETA does not establish real supplier availability."),
                "current", order_id, "warning" if overdue else "info",
            ))

    event_ids = set()
    for alert in state.alerts:
        if order_id is None or alert.order_id == order_id:
            event_ids.add(alert.event_id)
            history.append(Fact(
                "alert", alert.alert_id,
                f"Historical version {alert.version}: {alert.order_id} moved from "
                f"{alert.previous_risk} to {alert.new_risk}. {alert.message}",
                "history", alert.order_id, "warning",
            ))
    for event in state.recent_events:
        if order_id is None or event.event_id in event_ids or order_id in event.summary:
            history.append(Fact(
                "event", event.event_id,
                f"Historical event at version {event.version}: {event.summary}", "history",
            ))
    if order_id is None:
        # Keep the most recent inventory event visible even when older alerts exist.
        history.sort(key=lambda item: item.source_type != "event")

    proposals = [item for item in approvals.proposals if order_id is None or item.order_id == order_id]
    proposal_orders = {item.proposal_id: item.order_id for item in proposals}
    for item in proposals:
        stale = " It is stale and requires a fresh proposal before approval." if item.is_stale else ""
        procurement.append(Fact(
            "proposal", item.proposal_id,
            f"Proposal for {item.order_id}: {item.status}; {item.action_type}; "
            f"execution status {item.execution_status}.{stale}",
            "procurement", item.order_id, "warning" if item.status == "pending" else "info",
        ))
    for item in approvals.purchase_orders:
        if order_id and item.order_id != order_id:
            continue
        cost = (f"Estimated incremental cost: {item.estimated_incremental_cost} {item.currency or 'currency unavailable'}."
                if item.estimated_incremental_cost is not None else "Incremental cost is unavailable.")
        procurement.append(Fact(
            "purchase_order", item.purchase_order_id,
            f"Approved demo PO for {item.order_id}: {item.quantity} units of {item.material_id} from "
            f"{item.supplier_id}, modeled ETA {item.expected_delivery_date}. "
            f"Supplier commitment is simulated. {cost}",
            "procurement", item.order_id,
        ))
    for item in approvals.audit_logs:
        associated = proposal_orders.get(item.proposal_id)
        if order_id is None or associated == order_id:
            procurement.append(Fact(
                "audit", item.audit_id,
                f"Audit records {item.action} at inventory version {item.version}.",
                "procurement", associated,
            ))

    if focus == "recovery":
        for item in proposals[:2]:
            outcome = item.simulation.after
            before = item.simulation.before
            strategy = "alternate supplier" if item.action_type == "alternate_supplier_po" else "expedite existing lot"
            recovery.append(Fact(
                "simulation", item.proposal_id,
                f"Historical {strategy} simulation at version {item.snapshot_version}: "
                f"modeled delivery {before.projected_delivery_date or 'unavailable'} to "
                f"{outcome.projected_delivery_date or 'unavailable'}, risk {before.risk} to {outcome.risk}; "
                f"slack {before.slack_days if before.slack_days is not None else 'unavailable'} to "
                f"{outcome.slack_days if outcome.slack_days is not None else 'unavailable'} days. "
                "This was a conditional projection.",
                "recovery", item.order_id, variant=item.action_type,
            ))

    if not historical_only and (focus == "recovery" or (briefing and role == "planner")):
        for result in active[:3 if briefing else 1]:
            candidates = evaluate_candidates(state, result.order_id)
            for candidate in candidates[:2]:
                item = candidate.recommendation
                outcome = candidate.after[result.order_id]
                cost = (f"Estimated incremental cost: {item.estimated_incremental_cost} {item.currency or 'currency unavailable'}."
                        if item.estimated_incremental_cost is not None else "Incremental cost is unavailable.")
                recovery.append(Fact(
                    "recommendation", item.recommendation_id,
                    f"Hypothetical option for {result.order_id}: {item.title} for {item.quantity} units "
                    f"of {item.material_id}, proposed ETA {item.proposed_eta}. Modeled delivery "
                    f"{outcome.projected_delivery_date}, risk {outcome.risk}. Supplier availability is unconfirmed. {cost}",
                    "recovery", result.order_id,
                ))

    if order_id:
        priorities = {
            "history": (history, procurement, shortages, suppliers, recovery),
            "recovery": (recovery, procurement, history, shortages, suppliers),
            "procurement": (procurement, history, shortages, suppliers, recovery),
            "shortages": (shortages, suppliers, history, procurement, recovery),
        }
        ordered = [current, *priorities.get(focus, (shortages, suppliers, history, procurement, recovery))]
    elif focus == "procurement" or (briefing and role == "approver"):
        pending = [item for item in procurement if item.severity == "warning"]
        other = [item for item in procurement if item.severity != "warning"]
        ordered = [pending[:6], other[:6], history[:4], current[:3], shortages[:3]]
    elif focus == "history":
        ordered = [history[:8], current[:6], suppliers[:4], procurement[:4]]
    elif focus == "shortages":
        ordered = [shortages[:10], current[:6], suppliers[:4]]
    elif focus == "recovery":
        ordered = [recovery[:6], current[:6], procurement[:6], history[:4]]
    else:
        ordered = [current[:6], shortages[:5], suppliers[:4], recovery[:4], history[:3], procurement[:2]]
    return tuple(item for group in ordered for item in group)[:CONTEXT_LIMIT]


def evidence_for(index: int, fact: Fact) -> Evidence:
    return Evidence(evidence_id=f"E{index + 1}", source_type=fact.source_type,
                    source_id=fact.source_id, summary=fact.summary[:600])
