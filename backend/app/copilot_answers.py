"""Question-specific presentation of verified copilot evidence."""

import re
from typing import Literal

from app.copilot_evidence import Fact
from app.copilot_models import Evidence, Focus

Intent = Literal["default", "authorization", "attention", "shortages", "history", "recovered",
                 "historical_compare", "compare", "impact", "cost", "pending", "root_cause", "order_context"]


def interpret(question: str, order_id: str | None) -> Intent:
    text = " ".join(re.findall(r"[a-z]+", question.lower()))
    words = set(text.split())
    approval = bool(words & {"approve", "authorize", "authorise", "execute", "reject"})
    override = bool(words & {"ignore", "override", "bypass", "disregard"})
    if approval and (
        override
        or re.search(r"\b(?:can|could|will|would) you\b|\byourself\b|\b(?:please|go ahead and) (?:approve|execute|authorize)\b", text)
        or re.match(r"(?:approve|execute|authorize|reject)\b", text)
    ):
        return "authorization"
    if order_id is None and re.search(r"\b(?:this|that|the selected|the current) order\b", text):
        return "order_context"
    if words & {"compare", "versus", "vs", "tradeoffs"} and words & {
        "strategies", "strategy", "options", "recovery", "expedite", "supplier", "alternative",
    }:
        return "historical_compare" if words & {"historical", "previous", "previously", "prior", "original", "were"} else "compare"
    if words & {"cost", "costs", "price", "priced", "spend", "spent", "paid"} or "how much" in text:
        if words & {"cost", "costs", "price", "priced", "spend", "spent", "paid", "purchase", "po"}:
            return "cost"
    if words & {"impact", "effect", "help", "affected", "improved", "difference"} and words & {
        "purchase", "po", "procurement", "approved",
    }:
        return "impact"
    if words & {"recovered", "resolved", "restored", "rescued", "fixed"} and (order_id or "recovery" in words):
        return "recovered"
    if words & {"previously", "historical", "earlier", "originally"} or (
        "was" in words and words & {"critical", "delayed", "risk"}
    ):
        return "history"
    if words & {"shortage", "shortages", "shortfalls"} or "short on" in text:
        return "shortages"
    if words & {"immediate", "urgent", "attention", "prioritize", "prioritise"} and words & {"order", "orders", "risk", "attention"}:
        return "attention"
    if words & {"pending", "awaiting", "needs", "require", "requires"} and words & {"proposal", "proposals", "approval", "approvals"}:
        return "pending"
    if order_id and words & {"why", "cause", "causing", "reason"}:
        return "root_cause"
    return "default"


INTENT_FOCUS: dict[Intent, Focus] = {
    "attention": "overview", "shortages": "shortages", "history": "history",
    "recovered": "recovery", "historical_compare": "recovery", "compare": "recovery",
    "impact": "recovery", "cost": "procurement", "pending": "procurement", "root_cause": "current",
}


def priorities(intent: Intent, facts: tuple[Fact, ...]) -> tuple[int, ...]:
    sources = {
        "attention": ("order", "inventory"),
        "shortages": ("inventory",),
        "history": ("alert", "event", "order", "purchase_order", "audit"),
        "recovered": ("purchase_order", "simulation", "order", "event", "proposal", "audit"),
        "historical_compare": ("simulation", "purchase_order", "audit"),
        "compare": ("recommendation", "order"),
        "impact": ("purchase_order", "simulation", "order", "event", "proposal", "audit"),
        "cost": ("purchase_order",),
        "pending": ("proposal",),
        "root_cause": ("inventory", "order", "supplier"),
    }.get(intent, ())
    selected = []
    for source in sources:
        matches = [
            index for index, fact in enumerate(facts)
            if fact.source_type == source and (intent != "pending" or fact.severity == "warning")
        ]
        if intent == "pending" and not matches:
            matches = [index for index, fact in enumerate(facts) if fact.source_type == "proposal"][:1]
        if intent == "historical_compare" and source == "simulation":
            distinct = {}
            for index in matches:
                distinct.setdefault(facts[index].variant, index)
            matches = list(distinct.values())
        limit = 6 if intent in ("shortages", "pending") else 4 if source == "order" and intent == "attention" else 2 if source in ("inventory", "simulation", "recommendation") else 1
        selected.extend(matches[:limit])
    return tuple(selected[:6])


def render_answer(intent: Intent, items: tuple[Evidence, ...]) -> str | None:
    if intent == "default":
        return None
    if intent == "authorization":
        return (
            "No. The Copilot is read-only and cannot approve, reject, or execute purchase orders. "
            "An authorized human approver must review the proposal and record a decision. "
            "No approval or inventory action was taken."
        )
    if intent == "order_context":
        return "Which order should I check? Include the order ID or select the order in the dashboard."

    by_source: dict[str, list[Evidence]] = {}
    for item in items:
        by_source.setdefault(item.source_type, []).append(item)

    def lines(*sources: str) -> str:
        return "\n".join(
            f"{item.summary} [{item.evidence_id}]"
            for source in sources for item in by_source.get(source, ())
        )

    if intent == "historical_compare":
        simulations = by_source.get("simulation", ())
        if not simulations:
            return "A historical comparison is unavailable because no saved recovery simulation was found for this order."
        lead = (
            "Only one saved historical recovery simulation is available. A second strategy cannot be compared from the retained evidence."
            if len(simulations) == 1 else "These are the saved historical strategies. Their projected outcomes were conditional."
        )
        return lead + "\n" + lines("simulation", "purchase_order", "audit")
    if intent == "compare":
        if not by_source.get("recommendation"):
            return "No current recovery options improve the modeled outcome in this snapshot. Ask for historical strategies to review saved simulations."
        return "These are the current hypothetical recovery options. Compare their modeled delivery and supplier assumptions before proposing one.\n" + lines("recommendation", "order")
    if intent in ("recovered", "impact"):
        if not by_source.get("purchase_order"):
            return "An approved demo purchase order could not be verified in the available records.\n" + lines("order", "alert", "event")
        lead = "The approved demo purchase order added incoming supply for the order. It did not add physical stock."
        return lead + "\n" + lines("purchase_order", "simulation", "order", "alert", "event", "proposal", "audit")
    if intent == "root_cause":
        if by_source.get("inventory"):
            return "This order has an unresolved material shortage, so a delivery date cannot be projected.\n" + lines("inventory", "order", "supplier")
        return "The current projection shows how the order compares with its requested delivery date.\n" + lines("order", "supplier")
    if intent == "history":
        if not (by_source.get("alert") or by_source.get("event")):
            return "The cause is unavailable in the retained history for this order.\n" + lines("order")
        return lines("alert", "event", "order", "purchase_order")
    if intent == "attention":
        ordered = by_source.get("order", ())
        if not ordered:
            return "No orders are currently delayed, critical, or at risk in this snapshot."
        escalated = [item.source_id for item in ordered if "is delayed" in item.summary or "is critical" in item.summary]
        lead = (
            f"Review {', '.join(escalated)} first. Start with overdue orders and then check the shortages blocking critical orders."
            if escalated else "No delayed or critical orders were found. Monitor the listed at-risk orders."
        )
        return lead + "\n" + lines("order", "inventory")
    if intent == "shortages":
        shortages = by_source.get("inventory", ())
        if not shortages:
            return "There are no verified material shortages for the requested scope in this snapshot."
        materials = ", ".join(dict.fromkeys(item.source_id for item in shortages))
        return f"Current shortages involve {materials}. Review confirmed incoming supply before committing new delivery dates.\n" + lines("inventory")
    if intent == "cost":
        if not by_source.get("purchase_order"):
            return "No approved demo purchase order was found in the available records, so a cost cannot be verified."
        unavailable = all("Incremental cost is unavailable." in item.summary for item in by_source["purchase_order"])
        lead = "The approved demo purchase order has no recorded incremental cost." if unavailable else "The recorded amounts are incremental cost estimates for demo purchase orders."
        return lead + "\n" + lines("purchase_order")
    pending = [
        item for item in by_source.get("proposal", ())
        if ": pending;" in item.summary
    ]
    if not pending:
        return "No pending purchase proposals were found in the available records.\n" + lines("proposal")
    return "These proposals are pending human review. A stale proposal needs fresh evidence before approval.\n" + lines("proposal")
