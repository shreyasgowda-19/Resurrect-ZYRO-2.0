from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from app.inventory.models import InventoryModel, PositiveQuantity
from app.inventory.state import StateMaterial

MATERIAL_ID = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
Name = Annotated[str, Field(min_length=1, max_length=120)]
Unit = Annotated[str, Field(min_length=1, max_length=32)]
Threshold = Annotated[int, Field(strict=True, ge=0, le=2**53 - 1)]
Description = Annotated[str, Field(max_length=500)]


class MaterialExtra(InventoryModel):
    reorder_threshold: Threshold = 0
    description: Description | None = None


class WorkspaceMaterial(StateMaterial):
    reorder_threshold: Threshold
    description: Description | None


class MaterialMutation(InventoryModel):
    expected_version: PositiveQuantity
    mutation_id: Annotated[str, Field(min_length=1, max_length=128)]


class MaterialCreate(MaterialMutation):
    material_id: Annotated[str, Field(pattern=MATERIAL_ID)]
    name: Name
    unit: Unit
    reorder_threshold: Threshold
    description: Description | None = None

    @field_validator("material_id")
    @classmethod
    def canonical_id(cls, value: str) -> str:
        return value.upper()


class MaterialPatch(MaterialMutation):
    name: Name | None = None
    unit: Unit | None = None
    reorder_threshold: Threshold | None = None
    description: Description | None = None

    @model_validator(mode="after")
    def validate_fields(self):
        changes = self.model_fields_set - {"expected_version", "mutation_id"}
        if not changes:
            raise ValueError("Provide at least one material metadata field.")
        if any(getattr(self, field) is None for field in changes - {"description"}):
            raise ValueError("Only description may be null.")
        return self


class MaterialMutationResult(InventoryModel):
    status: Literal["applied", "duplicate"]
    workspace_id: str
    version: PositiveQuantity
    material: WorkspaceMaterial
