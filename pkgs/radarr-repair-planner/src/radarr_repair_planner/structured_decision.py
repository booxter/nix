from __future__ import annotations

import json

from .case_models import RepairCaseV1
from .contracts import ContractError, decision_schema, decode_decision, encode_case
from .decision_models import RepairDecisionV1
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
    repair_case: RepairCaseV1,
    correction: tuple[DecisionViolation, ...],
) -> tuple[str, str]:
    schema = json.dumps(
        decision_schema(),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    system_content = f"{system_instruction.rstrip()}\n\n{SCHEMA_INSTRUCTION}{schema}"
    if correction:
        system_content += "\n\n" + format_correction(correction)
    return system_content, encode_case(repair_case).decode()


def decode_structured_decision(raw_output: str) -> RepairDecisionV1:
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
        return decode_decision(payload)
    except ContractError as error:
        violations = validate_decision_object(value)
        detail = describe_violations(violations) if violations else diagnostic(error)
        raise StructuredDecisionError(
            "decision contract failed: " + detail,
            violations,
        ) from error
