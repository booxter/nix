from __future__ import annotations

from .decision_validation import DecisionViolation
from .lidarr_case_models import LidarrRepairCaseV1
from .lidarr_contracts import (
    decision_schema,
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)
from .lidarr_decision_models import (
    Explanation,
    LidarrRepairDecisionV1,
    NoRepair,
    Reason,
    Sha256Id,
)
from .lidarr_prompt import SYSTEM_INSTRUCTION
from .lidarr_validation import validate_decision_for_case, validate_decision_object
from .planning_core import ContractPlanner, DecisionModelError
from .structured_decision import StructuredDecisionError, decode_structured_output
from .structured_model import StructuredDecisionModel


class LidarrDecisionGenerator:
    def __init__(self, model: StructuredDecisionModel) -> None:
        self._model = model

    async def generate(
        self,
        repair_case: LidarrRepairCaseV1,
        correction: tuple[DecisionViolation, ...],
    ) -> LidarrRepairDecisionV1:
        try:
            raw = await self._model.decide_json(
                SYSTEM_INSTRUCTION,
                encode_case(repair_case).decode(),
                decision_schema(),
                repair_case.case_id.root,
                correction,
            )
            return decode_structured_output(raw, decode_decision, validate_decision_object)
        except StructuredDecisionError as error:
            raise DecisionModelError(
                "Lidarr " + str(error),
                error.violations,
            ) from error


def _roundtrip_case(repair_case: LidarrRepairCaseV1) -> LidarrRepairCaseV1:
    return decode_case(encode_case(repair_case))


def _roundtrip_decision(decision: LidarrRepairDecisionV1) -> LidarrRepairDecisionV1:
    return decode_decision(encode_decision(decision))


def _fallback(repair_case: LidarrRepairCaseV1) -> LidarrRepairDecisionV1:
    return _roundtrip_decision(
        LidarrRepairDecisionV1(
            root=NoRepair(
                action="no_repair",
                case_id=Sha256Id(root=repair_case.case_id.root),
                evidence_refs=[],
                explanation=Explanation(
                    root="The planner could not produce a valid decision within its attempt limit."
                ),
                reason=Reason.unsafe_to_repair,
                schema_version="lidarr-repair/v1",
            )
        )
    )


class LidarrPlanner(ContractPlanner[LidarrRepairCaseV1, LidarrRepairDecisionV1]):
    def __init__(self, model: StructuredDecisionModel) -> None:
        super().__init__(
            generator=LidarrDecisionGenerator(model),
            roundtrip_case=_roundtrip_case,
            roundtrip_decision=_roundtrip_decision,
            validate_decision=validate_decision_for_case,
            fallback=_fallback,
        )
