from __future__ import annotations

from typing import Protocol

from .case_models import RepairCaseV3
from .contracts import decode_case, decode_decision, encode_case, encode_decision
from .decision_models import (
    EvidenceRefs,
    NoRepair,
    Reason,
    RepairDecisionV3,
    SafeExplanation,
    Sha256Id,
)
from .decision_validation import validate_decision_for_case
from .decision_validation_core import DecisionViolation
from .planning_core import ContractPlanner
from .planning_core import DecisionModelError as DecisionModelError
from .planning_core import PlanningOutcome as PlanningOutcome
from .prompt import SYSTEM_INSTRUCTION


class DecisionModel(Protocol):
    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV3,
        correction: tuple[DecisionViolation, ...],
    ) -> RepairDecisionV3: ...


class RadarrDecisionGenerator:
    def __init__(self, model: DecisionModel) -> None:
        self._model = model

    async def generate(
        self,
        repair_case: RepairCaseV3,
        correction: tuple[DecisionViolation, ...],
    ) -> RepairDecisionV3:
        return await self._model.decide(SYSTEM_INSTRUCTION, repair_case, correction)


def _roundtrip_case(repair_case: RepairCaseV3) -> RepairCaseV3:
    return decode_case(encode_case(repair_case))


def _roundtrip_decision(decision: RepairDecisionV3) -> RepairDecisionV3:
    return decode_decision(encode_decision(decision))


def _fallback(repair_case: RepairCaseV3) -> RepairDecisionV3:
    decision = RepairDecisionV3(
        root=NoRepair(
            action="no_repair",
            case_id=Sha256Id(root=repair_case.case_id.root),
            evidence_refs=EvidenceRefs(root=[]),
            explanation=SafeExplanation(
                root="The planner could not produce a valid decision within its attempt limit."
            ),
            missing_evidence=[],
            reason=Reason.unsafe_to_repair,
            schema_version="radarr-repair/v3",
        )
    )
    return _roundtrip_decision(decision)


class Planner(ContractPlanner[RepairCaseV3, RepairDecisionV3]):
    def __init__(self, model: DecisionModel) -> None:
        super().__init__(
            generator=RadarrDecisionGenerator(model),
            roundtrip_case=_roundtrip_case,
            roundtrip_decision=_roundtrip_decision,
            validate_decision=validate_decision_for_case,
            fallback=_fallback,
            case_id=lambda repair_case: repair_case.case_id.root,
        )
