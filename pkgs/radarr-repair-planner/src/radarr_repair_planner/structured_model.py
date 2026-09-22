from __future__ import annotations

from typing import Any, Protocol

from .decision_validation import DecisionViolation


class StructuredDecisionModel(Protocol):
    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> str: ...
