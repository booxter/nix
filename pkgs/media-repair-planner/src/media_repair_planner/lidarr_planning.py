from __future__ import annotations

from .lidarr_case_models import LidarrRepairCaseV3
from .lidarr_contracts import (
    decision_schema,
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)
from .lidarr_decision_models import (
    Explanation,
    LidarrRepairDecisionV3,
    NoRepair,
    Reason,
    Sha256Id,
)
from .lidarr_projection import project_case
from .lidarr_prompt import SYSTEM_INSTRUCTION
from .lidarr_validation import validate_decision_for_case, validate_decision_object
from .planning_core import ContractPlanner
from .structured_model import StructuredDecisionModel
from .structured_planning import StructuredDecisionGenerator


def _roundtrip_case(repair_case: LidarrRepairCaseV3) -> LidarrRepairCaseV3:
    return decode_case(encode_case(repair_case))


def _roundtrip_decision(decision: LidarrRepairDecisionV3) -> LidarrRepairDecisionV3:
    return decode_decision(encode_decision(decision))


def _fallback(repair_case: LidarrRepairCaseV3) -> LidarrRepairDecisionV3:
    return _roundtrip_decision(
        LidarrRepairDecisionV3(
            root=NoRepair(
                action="no_repair",
                case_id=Sha256Id(root=repair_case.case_id.root),
                evidence_refs=[],
                explanation=Explanation(
                    root="The planner could not produce a valid decision within its attempt limit."
                ),
                reason=Reason.unsafe_to_repair,
                schema_version="lidarr-repair/v3",
            )
        )
    )


class LidarrPlanner(ContractPlanner[LidarrRepairCaseV3, LidarrRepairDecisionV3]):
    def __init__(self, model: StructuredDecisionModel) -> None:
        super().__init__(
            generator=StructuredDecisionGenerator(
                model=model,
                system_instruction=SYSTEM_INSTRUCTION,
                decision_schema=decision_schema,
                decision_model=LidarrRepairDecisionV3,
                project_case=project_case,
                decode_decision=decode_decision,
                validate_decision_object=validate_decision_object,
                case_id=lambda repair_case: repair_case.case_id.root,
            ),
            roundtrip_case=_roundtrip_case,
            roundtrip_decision=_roundtrip_decision,
            validate_decision=validate_decision_for_case,
            fallback=_fallback,
            case_id=lambda repair_case: repair_case.case_id.root,
        )
