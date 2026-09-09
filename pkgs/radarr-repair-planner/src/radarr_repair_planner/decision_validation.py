from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from .case_models import JoinCapability, ManualImportCapability, RepairCaseV1
from .decision_models import JoinParts, ManualImportFile, NoRepair, RepairDecisionV1


class ViolationCode(StrEnum):
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
    repair_case: RepairCaseV1
    decision: JoinParts | ManualImportFile | NoRepair


DecisionValidator = Callable[[ValidationContext], tuple[DecisionViolation, ...]]
Capability = JoinCapability | ManualImportCapability


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


def _reference_ids(repair_case: RepairCaseV1) -> tuple[str, ...]:
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
    repair_case: RepairCaseV1,
    decision: RepairDecisionV1,
) -> tuple[DecisionViolation, ...]:
    context = ValidationContext(repair_case=repair_case, decision=decision.root)
    return tuple(violation for validator in CASE_VALIDATORS for violation in validator(context))


def describe_violation(violation: DecisionViolation) -> str:
    match violation.code:
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
