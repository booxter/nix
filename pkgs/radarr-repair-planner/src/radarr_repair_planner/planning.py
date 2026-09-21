from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .case_models import RepairCaseV2
from .contracts import ContractError, decode_case, decode_decision, encode_case, encode_decision
from .decision_models import (
    EvidenceRefs,
    NoRepair,
    Reason,
    RepairDecisionV2,
    SafeExplanation,
    Sha256Id,
)
from .decision_validation import (
    DecisionViolation,
    describe_violations,
    validate_decision_for_case,
)
from .prompt import SYSTEM_INSTRUCTION

ATTEMPT_LIMIT = 2
ATTEMPT_ERROR_LIMIT = 512


class DecisionModelError(Exception):
    """An expected model call or structured-output failure."""

    def __init__(
        self,
        message: str,
        violations: tuple[DecisionViolation, ...] = (),
    ) -> None:
        super().__init__(message)
        self.violations = violations


class DecisionModel(Protocol):
    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV2,
        correction: tuple[DecisionViolation, ...],
    ) -> RepairDecisionV2: ...


@dataclass(frozen=True)
class PlanningOutcome:
    decision: RepairDecisionV2
    attempts: int
    used_fallback: bool
    attempt_errors: tuple[str, ...] = ()


def _attempt_error(attempt: int, detail: str) -> str:
    normalized = " ".join(detail.split())
    return f"attempt {attempt}: {normalized}"[:ATTEMPT_ERROR_LIMIT]


class Planner:
    def __init__(self, model: DecisionModel) -> None:
        self._model = model

    async def plan(self, repair_case: RepairCaseV2) -> RepairDecisionV2:
        return (await self.plan_with_outcome(repair_case)).decision

    async def plan_with_outcome(self, repair_case: RepairCaseV2) -> PlanningOutcome:
        validated_case = decode_case(encode_case(repair_case))
        correction: tuple[DecisionViolation, ...] = ()
        attempt_errors: list[str] = []
        for attempt in range(1, ATTEMPT_LIMIT + 1):
            decision, correction, error = await self._attempt(validated_case, correction)
            if decision is not None:
                return PlanningOutcome(
                    decision=decision,
                    attempts=attempt,
                    used_fallback=False,
                    attempt_errors=tuple(attempt_errors),
                )
            if error is None:
                raise RuntimeError("planning attempt failed without an error")
            attempt_errors.append(_attempt_error(attempt, error))

        return PlanningOutcome(
            decision=self._fallback(validated_case),
            attempts=ATTEMPT_LIMIT,
            used_fallback=True,
            attempt_errors=tuple(attempt_errors),
        )

    async def _attempt(
        self,
        repair_case: RepairCaseV2,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[RepairDecisionV2 | None, tuple[DecisionViolation, ...], str | None]:
        try:
            proposed = await self._model.decide(
                SYSTEM_INSTRUCTION,
                repair_case,
                correction,
            )
            decision = decode_decision(encode_decision(proposed))
        except ContractError as error:
            return None, (), f"decision contract failed: {error}"
        except DecisionModelError as error:
            return None, error.violations, str(error)
        violations = validate_decision_for_case(repair_case, decision)
        if violations:
            return None, violations, describe_violations(violations)
        return decision, (), None

    @staticmethod
    def _fallback(repair_case: RepairCaseV2) -> RepairDecisionV2:
        decision = RepairDecisionV2(
            root=NoRepair(
                action="no_repair",
                case_id=Sha256Id(root=repair_case.case_id.root),
                evidence_refs=EvidenceRefs(root=[]),
                explanation=SafeExplanation(
                    root=(
                        "The planner could not produce a valid decision within its attempt limit."
                    )
                ),
                missing_evidence=[],
                reason=Reason.unsafe_to_repair,
                schema_version="radarr-repair/v2",
            )
        )
        return decode_decision(encode_decision(decision))
