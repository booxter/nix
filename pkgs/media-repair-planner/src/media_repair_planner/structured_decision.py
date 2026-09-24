from __future__ import annotations

import json
from collections.abc import Callable

from .contracts import ContractError, decode_decision
from .decision_models import RepairDecisionV3
from .decision_validation import validate_decision_object
from .decision_validation_core import (
    DecisionViolation,
    describe_violations,
    format_correction,
    non_object_violation,
    parsing_violation,
)

ERROR_DETAIL_LIMIT = 384


class StructuredDecisionError(ValueError):
    """A model response that cannot be decoded as a repair decision."""

    def __init__(
        self,
        message: str,
        violations: tuple[DecisionViolation, ...] = (),
    ) -> None:
        super().__init__(message)
        self.violations = violations


def diagnostic(error: BaseException) -> str:
    detail = " ".join(str(error).split())
    return (type(error).__name__ + (f": {detail}" if detail else ""))[:ERROR_DETAIL_LIMIT]


def structured_prompt(
    system_instruction: str,
    case_content: str,
    correction: tuple[DecisionViolation, ...],
) -> tuple[str, str]:
    system_content = system_instruction.rstrip()
    if correction:
        system_content += "\n\n" + format_correction(correction)
    return system_content, case_content


def decode_structured_decision(raw_output: str) -> RepairDecisionV3:
    return decode_structured_output(raw_output, decode_decision, validate_decision_object)


def decode_structured_output[DecisionT](
    raw_output: str,
    decoder: Callable[[bytes], DecisionT],
    validate_object: Callable[[dict[str, object]], tuple[DecisionViolation, ...]],
) -> DecisionT:
    try:
        value = json.loads(raw_output)
    except json.JSONDecodeError as error:
        violation = parsing_violation(extra_output=error.msg == "Extra data")
        raise StructuredDecisionError(
            "structured decoding failed: " + diagnostic(error),
            (violation,),
        ) from error
    if not isinstance(value, dict):
        raise StructuredDecisionError(
            "structured output was not an object",
            (non_object_violation(),),
        )
    try:
        payload = json.dumps(value, allow_nan=False).encode()
    except (TypeError, ValueError) as error:
        raise StructuredDecisionError("structured output was not JSON") from error
    try:
        return decoder(payload)
    except ContractError as error:
        violations = validate_object(value)
        detail = describe_violations(violations) if violations else diagnostic(error)
        raise StructuredDecisionError(
            "decision contract failed: " + detail,
            violations,
        ) from error
