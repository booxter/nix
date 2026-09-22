from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

from .case_models import (
    BlurayCapability,
    DvdCapability,
    JoinCapability,
    ManualImportCapability,
    RepairCaseV2,
)
from .contracts import decision_schema
from .decision_models import (
    JoinParts,
    ManualImportFile,
    NoRepair,
    RemuxBluray,
    RemuxDVD,
    RepairDecisionV2,
)

MAX_CORRECTION_VIOLATIONS = 8
MAX_CORRECTION_VALUES = 4
MAX_CORRECTION_LENGTH = 2048
SAFE_NAME = re.compile(r"^[a-z][a-z0-9_]{0,63}$")


class ViolationCode(StrEnum):
    INVALID_JSON = "invalid_json"
    EXTRA_OUTPUT = "extra_output"
    NON_OBJECT_JSON = "non_object_json"
    MISSING_FIELD = "missing_field"
    UNKNOWN_FIELD = "unknown_field"
    INVALID_FIELD = "invalid_field"
    CASE_ID_MISMATCH = "case_id_mismatch"
    UNKNOWN_EVIDENCE = "unknown_evidence"
    UNKNOWN_CAPABILITY = "unknown_capability"
    ACTION_CAPABILITY_MISMATCH = "action_capability_mismatch"
    FILE_OUTSIDE_CAPABILITY = "file_outside_capability"
    MANUAL_IMPORT_FILE_MISMATCH = "manual_import_file_mismatch"


@dataclass(frozen=True)
class DecisionViolation:
    code: ViolationCode
    path: tuple[str | int, ...]
    rejected_values: tuple[str, ...] = ()
    allowed_values: tuple[str, ...] = ()


@dataclass(frozen=True)
class ValidationContext:
    repair_case: RepairCaseV2
    decision: JoinParts | ManualImportFile | NoRepair | RemuxBluray | RemuxDVD


DecisionValidator = Callable[[ValidationContext], tuple[DecisionViolation, ...]]
Capability = JoinCapability | ManualImportCapability | BlurayCapability | DvdCapability


def parsing_violation(*, extra_output: bool = False) -> DecisionViolation:
    return DecisionViolation(
        code=(ViolationCode.EXTRA_OUTPUT if extra_output else ViolationCode.INVALID_JSON),
        path=(),
    )


def non_object_violation() -> DecisionViolation:
    return DecisionViolation(code=ViolationCode.NON_OBJECT_JSON, path=())


def _branch_schema(
    action: str,
    schema: dict[str, Any],
    branch_names: dict[str, str],
) -> dict[str, Any] | None:
    branch_name = branch_names.get(action)
    if branch_name is None:
        return None
    return {
        "$schema": schema["$schema"],
        "$defs": schema["$defs"],
        "$ref": f"#/$defs/{branch_name}",
    }


def validate_object_against_action_schema(
    value: dict[str, object],
    contract_schema: dict[str, Any],
    branch_names: dict[str, str],
) -> tuple[DecisionViolation, ...]:
    action = value.get("action")
    if action is None:
        return (
            DecisionViolation(
                code=ViolationCode.MISSING_FIELD,
                path=("action",),
            ),
        )
    schema = (
        _branch_schema(action, contract_schema, branch_names) if isinstance(action, str) else None
    )
    if schema is None:
        return (
            DecisionViolation(
                code=ViolationCode.INVALID_FIELD,
                path=("action",),
                allowed_values=tuple(branch_names),
            ),
        )

    violations: list[DecisionViolation] = []
    for error in Draft202012Validator(schema).iter_errors(value):
        path = tuple(error.absolute_path)
        if error.validator == "required":
            required = error.validator_value
            if isinstance(required, list):
                violations.extend(
                    DecisionViolation(
                        code=ViolationCode.MISSING_FIELD,
                        path=(*path, field),
                    )
                    for field in required
                    if isinstance(field, str) and field not in error.instance
                )
            continue
        if error.validator == "additionalProperties" and isinstance(error.instance, dict):
            unknown = _safe_unknown_fields(
                error.instance,
                error.schema.get("properties"),
            )
            violations.append(
                DecisionViolation(
                    code=ViolationCode.UNKNOWN_FIELD,
                    path=path,
                    rejected_values=unknown,
                )
            )
            continue
        allowed: tuple[str, ...] = ()
        if error.validator == "const" and isinstance(error.validator_value, str):
            allowed = (error.validator_value,)
        elif error.validator == "enum" and isinstance(error.validator_value, list):
            allowed = tuple(item for item in error.validator_value if isinstance(item, str))
        violations.append(
            DecisionViolation(
                code=ViolationCode.INVALID_FIELD,
                path=path,
                allowed_values=allowed,
            )
        )
    return tuple(
        dict.fromkeys(
            sorted(
                violations,
                key=lambda violation: (
                    violation.code.value,
                    tuple(str(item) for item in violation.path),
                    violation.rejected_values,
                    violation.allowed_values,
                ),
            )
        )
    )


def validate_decision_object(value: dict[str, object]) -> tuple[DecisionViolation, ...]:
    branch_names = {
        "join_parts_v1": "joinParts",
        "manual_import_file_v1": "manualImportFile",
        "remux_bluray_v1": "remuxBluray",
        "remux_dvd_v1": "remuxDVD",
        "no_repair": "noRepair",
    }
    return validate_object_against_action_schema(value, decision_schema(), branch_names)


def _safe_unknown_fields(value: dict[str, object], properties: object) -> tuple[str, ...]:
    if not isinstance(properties, dict):
        return ()
    return tuple(
        sorted(
            key for key in value.keys() - properties.keys() if SAFE_NAME.fullmatch(key) is not None
        )
    )


def _case_id(context: ValidationContext) -> tuple[DecisionViolation, ...]:
    actual = context.decision.case_id.root
    expected = context.repair_case.case_id.root
    if actual == expected:
        return ()
    return (
        DecisionViolation(
            code=ViolationCode.CASE_ID_MISMATCH,
            path=("case_id",),
            rejected_values=(actual,),
            allowed_values=(expected,),
        ),
    )


def _reference_ids(repair_case: RepairCaseV2) -> tuple[str, ...]:
    values = {
        *(capability.capability_id.root for capability in repair_case.capabilities),
        *(media_file.file_id.root for media_file in repair_case.files),
        *(manual_import.file_id.root for manual_import in repair_case.radarr.manual_imports),
        *(message.evidence_id.root for message in repair_case.radarr.failure.status_messages),
        *(event.evidence_id.root for event in repair_case.radarr.history),
        *(
            rejection.evidence_id.root
            for manual_import in repair_case.radarr.manual_imports
            for rejection in manual_import.rejections
        ),
    }
    return tuple(sorted(values))


def _evidence_refs(context: ValidationContext) -> tuple[DecisionViolation, ...]:
    allowed = _reference_ids(context.repair_case)
    rejected = tuple(
        sorted(
            {
                reference.root
                for reference in context.decision.evidence_refs.root
                if reference.root not in allowed
            }
        )
    )
    if not rejected:
        return ()
    return (
        DecisionViolation(
            code=ViolationCode.UNKNOWN_EVIDENCE,
            path=("evidence_refs",),
            rejected_values=rejected,
            allowed_values=allowed,
        ),
    )


def _selected_capability(context: ValidationContext) -> Capability | None:
    assert not isinstance(context.decision, NoRepair)
    selected_id = context.decision.capability_id.root
    return next(
        (
            capability
            for capability in context.repair_case.capabilities
            if capability.capability_id.root == selected_id
        ),
        None,
    )


def _capability(context: ValidationContext) -> tuple[DecisionViolation, ...]:
    if isinstance(context.decision, NoRepair):
        return ()
    selected = _selected_capability(context)
    if selected is None:
        return (
            DecisionViolation(
                code=ViolationCode.UNKNOWN_CAPABILITY,
                path=("capability_id",),
                rejected_values=(context.decision.capability_id.root,),
                allowed_values=tuple(
                    sorted(
                        capability.capability_id.root
                        for capability in context.repair_case.capabilities
                    )
                ),
            ),
        )
    if selected.action == context.decision.action:
        return ()
    return (
        DecisionViolation(
            code=ViolationCode.ACTION_CAPABILITY_MISMATCH,
            path=("action",),
            rejected_values=(context.decision.action,),
            allowed_values=(selected.action,),
        ),
    )


def _selected_files(context: ValidationContext) -> tuple[DecisionViolation, ...]:
    if isinstance(context.decision, NoRepair):
        return ()
    capability = _selected_capability(context)
    if capability is None or capability.action != context.decision.action:
        return ()
    if isinstance(context.decision, (RemuxBluray, RemuxDVD)):
        return ()
    if isinstance(context.decision, JoinParts):
        assert isinstance(capability, JoinCapability)
        allowed = tuple(file_id.root for file_id in capability.candidate_file_ids)
        rejected = tuple(
            file_id.root
            for file_id in context.decision.ordered_file_ids
            if file_id.root not in allowed
        )
        if not rejected:
            return ()
        return (
            DecisionViolation(
                code=ViolationCode.FILE_OUTSIDE_CAPABILITY,
                path=("ordered_file_ids",),
                rejected_values=rejected,
                allowed_values=allowed,
            ),
        )
    assert isinstance(capability, ManualImportCapability)
    if context.decision.file_id.root == capability.file_id.root:
        return ()
    return (
        DecisionViolation(
            code=ViolationCode.MANUAL_IMPORT_FILE_MISMATCH,
            path=("file_id",),
            rejected_values=(context.decision.file_id.root,),
            allowed_values=(capability.file_id.root,),
        ),
    )


CASE_VALIDATORS: tuple[DecisionValidator, ...] = (
    _case_id,
    _evidence_refs,
    _capability,
    _selected_files,
)


def validate_decision_for_case(
    repair_case: RepairCaseV2,
    decision: RepairDecisionV2,
) -> tuple[DecisionViolation, ...]:
    context = ValidationContext(repair_case=repair_case, decision=decision.root)
    return tuple(violation for validator in CASE_VALIDATORS for violation in validator(context))


def describe_violation(violation: DecisionViolation) -> str:
    match violation.code:
        case ViolationCode.INVALID_JSON:
            return "response is not valid JSON"
        case ViolationCode.EXTRA_OUTPUT:
            return "response contains text or another value outside its JSON object"
        case ViolationCode.NON_OBJECT_JSON:
            return "response JSON is not an object"
        case ViolationCode.MISSING_FIELD:
            return f"decision is missing required field at {_path(violation.path)}"
        case ViolationCode.UNKNOWN_FIELD:
            return f"decision contains a field the schema does not allow at {_path(violation.path)}"
        case ViolationCode.INVALID_FIELD:
            return f"decision field does not satisfy the schema at {_path(violation.path)}"
        case ViolationCode.CASE_ID_MISMATCH:
            return "decision case_id does not match the case"
        case ViolationCode.UNKNOWN_EVIDENCE:
            return "decision references evidence absent from the case"
        case ViolationCode.UNKNOWN_CAPABILITY:
            return "decision references a capability absent from the case"
        case ViolationCode.ACTION_CAPABILITY_MISMATCH:
            return "decision action does not match its capability"
        case ViolationCode.FILE_OUTSIDE_CAPABILITY:
            return "join selects files outside its capability"
        case ViolationCode.MANUAL_IMPORT_FILE_MISMATCH:
            return "manual import file does not match its capability"
    raise AssertionError(f"unsupported decision violation: {violation.code}")


def describe_violations(violations: tuple[DecisionViolation, ...]) -> str:
    return "; ".join(describe_violation(violation) for violation in violations)


def _path(path: tuple[str | int, ...]) -> str:
    return ".".join(str(item) for item in path) or "response"


def _values(values: tuple[str, ...]) -> str:
    visible = values[:MAX_CORRECTION_VALUES]
    result = ", ".join(f"`{value}`" for value in visible)
    if len(values) > len(visible):
        result += f", and {len(values) - len(visible)} more"
    return result


def _correction_line(violation: DecisionViolation) -> str:
    path = _path(violation.path)
    match violation.code:
        case ViolationCode.INVALID_JSON:
            return "The response was not valid JSON."
        case ViolationCode.EXTRA_OUTPUT:
            return "Return no text or additional JSON values outside the decision object."
        case ViolationCode.NON_OBJECT_JSON:
            return "The response must be one JSON object."
        case ViolationCode.MISSING_FIELD:
            return f"`{path}` is required."
        case ViolationCode.UNKNOWN_FIELD:
            if violation.rejected_values:
                return f"These fields are not allowed: {_values(violation.rejected_values)}."
            return "The response contains a field that is not allowed."
        case ViolationCode.INVALID_FIELD:
            if violation.allowed_values:
                return f"`{path}` must be one of: {_values(violation.allowed_values)}."
            return f"`{path}` does not satisfy the response schema."
        case ViolationCode.CASE_ID_MISMATCH:
            return f"`case_id` must be copied exactly as {_values(violation.allowed_values)}."
        case ViolationCode.UNKNOWN_EVIDENCE:
            return (
                f"These `evidence_refs` are absent: {_values(violation.rejected_values)}. "
                f"Available references are: {_values(violation.allowed_values)}."
            )
        case ViolationCode.UNKNOWN_CAPABILITY:
            return (
                f"This capability is absent: {_values(violation.rejected_values)}. "
                f"Available capabilities are: {_values(violation.allowed_values)}."
            )
        case ViolationCode.ACTION_CAPABILITY_MISMATCH:
            return f"The selected capability only supports: {_values(violation.allowed_values)}."
        case ViolationCode.FILE_OUTSIDE_CAPABILITY:
            return (
                f"These join files are not offered: {_values(violation.rejected_values)}. "
                f"Candidate files are: {_values(violation.allowed_values)}."
            )
        case ViolationCode.MANUAL_IMPORT_FILE_MISMATCH:
            return f"The manual import capability only offers: {_values(violation.allowed_values)}."
    raise AssertionError(f"unsupported decision violation: {violation.code}")


def format_correction(violations: tuple[DecisionViolation, ...]) -> str:
    selected = violations[:MAX_CORRECTION_VIOLATIONS]
    lines = ["Your previous response was rejected:"]
    for number, violation in enumerate(selected, start=1):
        line = f"{number}. {_correction_line(violation)}"
        if len("\n".join([*lines, line])) > MAX_CORRECTION_LENGTH - 128:
            break
        lines.append(line)
    omitted = len(violations) - (len(lines) - 1)
    if omitted:
        lines.append(f"{omitted} additional violations were omitted.")
    lines.append("Return one complete JSON object matching the authoritative schema.")
    return "\n".join(lines)
