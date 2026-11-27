from typing import Annotated, Literal

from pydantic import Field

from app.auth import Role
from app.inventory.models import Identifier, InventoryModel, PositiveQuantity

Source = Literal["inventory", "order", "supplier", "event", "alert", "recommendation",
                 "simulation", "proposal", "purchase_order", "audit"]
Mode = Literal["gemini", "deterministic_fallback"]
Focus = Literal["overview", "current", "shortages", "history", "recovery", "procurement"]


class AskRequest(InventoryModel):
    question: Annotated[str, Field(min_length=1, max_length=1000)]
    order_id: Identifier | None = None
    expected_version: PositiveQuantity


class Evidence(InventoryModel):
    evidence_id: str
    source_type: Source
    source_id: str
    summary: str


class Insight(InventoryModel):
    title: str
    description: str
    severity: Literal["info", "warning", "critical"]
    order_id: str | None
    evidence: tuple[Evidence, ...]
    suggested_question: str


class AskResponse(InventoryModel):
    version: PositiveQuantity
    role: Role
    mode: Mode
    answer: str
    evidence: tuple[Evidence, ...]
    suggested_questions: tuple[str, ...]
    warnings: tuple[str, ...]


class BriefingResponse(InventoryModel):
    version: PositiveQuantity
    role: Role
    mode: Mode
    headline: str
    summary: str
    insights: tuple[Insight, ...]
    warnings: tuple[str, ...]


class Selection(InventoryModel):
    focus: Focus
    evidence_ids: Annotated[tuple[str, ...], Field(min_length=1, max_length=6)]
