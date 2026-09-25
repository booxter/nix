from __future__ import annotations

import json
from dataclasses import dataclass

from .decision_validation_core import DecisionViolation

MODEL_CASE_ID = "sha256:" + "0" * 64


def objects(value: object, field: str) -> list[dict[str, object]]:
    if not isinstance(value, dict):
        raise ValueError("encoded repair case is not an object")
    items = value.get(field)
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ValueError(f"encoded repair case has invalid {field}")
    return items


def identifier(item: object, field: str) -> str:
    if not isinstance(item, dict):
        raise ValueError("encoded repair case is not an object")
    value = item.get(field)
    if not isinstance(value, str):
        raise ValueError(f"encoded repair case has invalid {field}")
    return value


def transform(
    value: object,
    replacements: dict[str, str],
    omitted_fields: frozenset[str] = frozenset(),
) -> object:
    if isinstance(value, dict):
        return {
            key: transform(item, replacements, omitted_fields)
            for key, item in value.items()
            if isinstance(key, str) and key not in omitted_fields
        }
    if isinstance(value, list):
        return [transform(item, replacements, omitted_fields) for item in value]
    if isinstance(value, str):
        return replacements.get(value, value)
    return value


def compact_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


@dataclass(frozen=True)
class IdentifierAliases:
    projected: dict[str, str]
    canonical: dict[str, str]

    @classmethod
    def create(cls, projected: dict[str, str]) -> IdentifierAliases:
        return cls(
            projected=projected,
            canonical={alias: original for original, alias in projected.items()},
        )

    def project_correction(
        self,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[DecisionViolation, ...]:
        return tuple(
            DecisionViolation(
                code=item.code,
                path=item.path,
                rejected_values=tuple(
                    self.projected.get(value, value) for value in item.rejected_values
                ),
                allowed_values=tuple(
                    self.projected.get(value, value) for value in item.allowed_values
                ),
            )
            for item in correction
        )

    def restore(self, value: object) -> object:
        return transform(value, self.canonical)
