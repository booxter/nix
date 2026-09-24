from __future__ import annotations

from collections.abc import Callable
from typing import Any, Protocol

from pydantic import BaseModel

from .decision_validation_core import DecisionViolation


class StructuredModelResponse:
    def __init__(
        self,
        content: str,
        source: str,
        finish: Callable[[str | None], None] | None = None,
    ) -> None:
        self.content = content
        self.source = source
        self._finish = finish
        self._finished = False

    def finish(self, error: str | None) -> None:
        if self._finished:
            raise RuntimeError("structured model response was already finished")
        self._finished = True
        if self._finish is not None:
            self._finish(error)


class StructuredDecisionModel(Protocol):
    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> StructuredModelResponse: ...
