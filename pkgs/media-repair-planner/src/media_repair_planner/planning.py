from __future__ import annotations

from .case_models import RepairCaseV3
from .contracts import decode_decision
from .decision_models import (
    EvidenceRefs,
    NoRepair,
    Reason,
    RepairDecisionV3,
    SafeExplanation,
    Sha256Id,
)
from .decision_validation import validate_decision_for_case, validate_decision_object
from .planning_core import ContractPlanner
from .planning_core import DecisionModelError as DecisionModelError
from .planning_core import DecisionModelUnavailable as DecisionModelUnavailable
from .prompt import SYSTEM_INSTRUCTION
from .radarr_projection import project_case
from .structured_model import StructuredDecisionModel
from .structured_planning import StructuredDecisionGenerator


def _fallback(repair_case: RepairCaseV3) -> RepairDecisionV3:
    return RepairDecisionV3(
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


class Planner(ContractPlanner[RepairCaseV3, RepairDecisionV3]):
    def __init__(self, model: StructuredDecisionModel) -> None:
        super().__init__(
            generator=StructuredDecisionGenerator(
                model=model,
                system_instruction=SYSTEM_INSTRUCTION,
                decision_model=RepairDecisionV3,
                project_case=project_case,
                decode_decision=decode_decision,
                validate_decision_object=validate_decision_object,
                case_id=lambda repair_case: repair_case.case_id.root,
            ),
            validate_decision=validate_decision_for_case,
            fallback=_fallback,
            case_id=lambda repair_case: repair_case.case_id.root,
        )
