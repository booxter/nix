from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

from .case_models import RepairCaseV3
from .contracts import ContractError, decision_schema, decode_decision, encode_case
from .decision_models import RepairDecisionV3
from .decision_validation import (
    DecisionViolation,
    describe_violations,
    format_correction,
    non_object_violation,
    parsing_violation,
    validate_decision_object,
)

ERROR_DETAIL_LIMIT = 384
SCHEMA_INSTRUCTION = """\
The authoritative response JSON Schema follows. Return only one JSON object
that validates against it, without Markdown fences or surrounding text.
"""


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


def decision_prompt(
    system_instruction: str,
    repair_case: RepairCaseV3,
    correction: tuple[DecisionViolation, ...],
    schema_instruction: str = SCHEMA_INSTRUCTION,
) -> tuple[str, str]:
    return structured_prompt(
        system_instruction,
        encode_case(repair_case).decode(),
        decision_schema(),
        correction,
        schema_instruction,
    )


def structured_prompt(
    system_instruction: str,
    case_content: str,
    schema_value: dict[str, Any],
    correction: tuple[DecisionViolation, ...],
    schema_instruction: str = SCHEMA_INSTRUCTION,
) -> tuple[str, str]:
    schema = json.dumps(
        schema_value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    system_content = f"{system_instruction.rstrip()}\n\n{schema_instruction}{schema}"
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
