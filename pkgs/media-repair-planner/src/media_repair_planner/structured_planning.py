from __future__ import annotations

from collections.abc import Callable
from typing import Any, Protocol

from pydantic import BaseModel

from .decision_validation_core import DecisionViolation
from .planning_core import DecisionModelError
from .structured_decision import StructuredDecisionError, decode_structured_output
from .structured_model import StructuredDecisionModel


class DecisionProjection[DecisionT](Protocol):
    @property
    def case_content(self) -> str: ...

    def project_correction(
        self,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[DecisionViolation, ...]: ...

    def restore_decision(self, decision: DecisionT) -> DecisionT: ...


class StructuredDecisionGenerator[CaseT, DecisionT]:
    def __init__(
        self,
        *,
        model: StructuredDecisionModel,
        system_instruction: str,
        decision_schema: Callable[[], dict[str, Any]],
        decision_model: type[BaseModel],
        project_case: Callable[[CaseT], DecisionProjection[DecisionT]],
        decode_decision: Callable[[bytes], DecisionT],
        validate_decision_object: Callable[[dict[str, object]], tuple[DecisionViolation, ...]],
        case_id: Callable[[CaseT], str],
    ) -> None:
        self._model = model
        self._system_instruction = system_instruction
        self._decision_schema = decision_schema
        self._decision_model = decision_model
        self._project_case = project_case
        self._decode_decision = decode_decision
        self._validate_decision_object = validate_decision_object
        self._case_id = case_id

    async def generate(
        self,
        repair_case: CaseT,
        correction: tuple[DecisionViolation, ...],
    ) -> DecisionT:
        projection = self._project_case(repair_case)
        response = await self._model.decide_json(
            self._system_instruction,
            projection.case_content,
            self._decision_schema(),
            self._decision_model,
            self._case_id(repair_case),
            projection.project_correction(correction),
        )
        try:
            decision = decode_structured_output(
                response.content,
                self._decode_decision,
                self._validate_decision_object,
            )
        except StructuredDecisionError as error:
            response.finish(str(error))
            raise DecisionModelError(
                response.source + " " + str(error),
                error.violations,
            ) from error
        response.finish(None)
        return projection.restore_decision(decision)
