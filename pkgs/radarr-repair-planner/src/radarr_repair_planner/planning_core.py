from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from .decision_validation import DecisionViolation, describe_violations
from .json_contract import ContractError

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


class DecisionGenerator[CaseT, DecisionT](Protocol):
    async def generate(
        self,
        repair_case: CaseT,
        correction: tuple[DecisionViolation, ...],
    ) -> DecisionT: ...


@dataclass(frozen=True)
class PlanningOutcome[DecisionT]:
    decision: DecisionT
    attempts: int
    used_fallback: bool
    attempt_errors: tuple[str, ...] = ()


def _attempt_error(attempt: int, detail: str) -> str:
    normalized = " ".join(detail.split())
    return f"attempt {attempt}: {normalized}"[:ATTEMPT_ERROR_LIMIT]


class ContractPlanner[CaseT, DecisionT]:
    def __init__(
        self,
        generator: DecisionGenerator[CaseT, DecisionT],
        roundtrip_case: Callable[[CaseT], CaseT],
        roundtrip_decision: Callable[[DecisionT], DecisionT],
        validate_decision: Callable[[CaseT, DecisionT], tuple[DecisionViolation, ...]],
        fallback: Callable[[CaseT], DecisionT],
    ) -> None:
        self._generator = generator
        self._roundtrip_case = roundtrip_case
        self._roundtrip_decision = roundtrip_decision
        self._validate_decision = validate_decision
        self._fallback = fallback

    async def plan(self, repair_case: CaseT) -> DecisionT:
        return (await self.plan_with_outcome(repair_case)).decision

    async def plan_with_outcome(self, repair_case: CaseT) -> PlanningOutcome[DecisionT]:
        validated_case = self._roundtrip_case(repair_case)
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
        repair_case: CaseT,
        correction: tuple[DecisionViolation, ...],
    ) -> tuple[DecisionT | None, tuple[DecisionViolation, ...], str | None]:
        try:
            proposed = await self._generator.generate(repair_case, correction)
            decision = self._roundtrip_decision(proposed)
        except ContractError as error:
            return None, (), f"decision contract failed: {error}"
        except DecisionModelError as error:
            return None, error.violations, str(error)
        violations = self._validate_decision(repair_case, decision)
        if violations:
            return None, violations, describe_violations(violations)
        return decision, (), None
