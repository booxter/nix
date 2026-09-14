from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol, TypedDict, cast

from langgraph.graph import END, START, StateGraph
from langgraph.graph.state import CompiledStateGraph

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


class PlanningState(TypedDict):
    repair_case: RepairCaseV2
    attempts: int
    attempt_errors: list[str]
    decision: RepairDecisionV2 | None
    correction: tuple[DecisionViolation, ...]
    used_fallback: bool


class PlanningUpdate(TypedDict, total=False):
    attempts: int
    attempt_errors: list[str]
    decision: RepairDecisionV2 | None
    correction: tuple[DecisionViolation, ...]
    used_fallback: bool


Route = Literal["done", "retry", "fallback"]


@dataclass(frozen=True)
class PlanningOutcome:
    decision: RepairDecisionV2
    attempts: int
    used_fallback: bool
    attempt_errors: tuple[str, ...] = ()


def _attempt_error(attempt: int, detail: str) -> str:
    normalized = " ".join(detail.split())
    return f"attempt {attempt}: {normalized}"[:ATTEMPT_ERROR_LIMIT]


class PlanningGraph:
    def __init__(self, model: DecisionModel) -> None:
        self._model = model
        builder = StateGraph[PlanningState, None, PlanningState, PlanningState](PlanningState)
        builder.add_node("attempt", self._attempt)
        builder.add_node("fallback", self._fallback)
        builder.add_edge(START, "attempt")
        builder.add_conditional_edges(
            "attempt",
            self._route,
            {
                "done": END,
                "retry": "attempt",
                "fallback": "fallback",
            },
        )
        builder.add_edge("fallback", END)
        self._graph: CompiledStateGraph[PlanningState, None, PlanningState, PlanningState] = (
            builder.compile(name="radarr-repair-planner")
        )

    async def plan(self, repair_case: RepairCaseV2) -> RepairDecisionV2:
        return (await self.plan_with_outcome(repair_case)).decision

    async def plan_with_outcome(self, repair_case: RepairCaseV2) -> PlanningOutcome:
        validated_case = decode_case(encode_case(repair_case))
        result = cast(
            PlanningState,
            await self._graph.ainvoke(
                {
                    "repair_case": validated_case,
                    "attempts": 0,
                    "attempt_errors": [],
                    "decision": None,
                    "correction": (),
                    "used_fallback": False,
                }
            ),
        )
        decision = result["decision"]
        if decision is None:
            raise RuntimeError("planning graph completed without a decision")
        return PlanningOutcome(
            decision=decode_decision(encode_decision(decision)),
            attempts=result["attempts"],
            used_fallback=result["used_fallback"],
            attempt_errors=tuple(result["attempt_errors"]),
        )

    async def _attempt(self, state: PlanningState) -> PlanningUpdate:
        attempts = state["attempts"] + 1
        try:
            proposed = await self._model.decide(
                SYSTEM_INSTRUCTION,
                state["repair_case"],
                state["correction"],
            )
            decision = decode_decision(encode_decision(proposed))
        except ContractError as error:
            return {
                "attempts": attempts,
                "attempt_errors": [
                    *state["attempt_errors"],
                    _attempt_error(attempts, f"decision contract failed: {error}"),
                ],
                "correction": (),
                "decision": None,
            }
        except DecisionModelError as error:
            return {
                "attempts": attempts,
                "attempt_errors": [
                    *state["attempt_errors"],
                    _attempt_error(attempts, str(error)),
                ],
                "correction": error.violations,
                "decision": None,
            }
        violations = validate_decision_for_case(state["repair_case"], decision)
        if violations:
            return {
                "attempts": attempts,
                "attempt_errors": [
                    *state["attempt_errors"],
                    _attempt_error(attempts, describe_violations(violations)),
                ],
                "correction": violations,
                "decision": None,
            }
        return {"attempts": attempts, "correction": (), "decision": decision}

    @staticmethod
    def _route(state: PlanningState) -> Route:
        if state["decision"] is not None:
            return "done"
        if state["attempts"] < ATTEMPT_LIMIT:
            return "retry"
        return "fallback"

    @staticmethod
    def _fallback(state: PlanningState) -> PlanningUpdate:
        case_id = Sha256Id(root=state["repair_case"].case_id.root)
        return {
            "decision": RepairDecisionV2(
                root=NoRepair(
                    action="no_repair",
                    case_id=case_id,
                    evidence_refs=EvidenceRefs(root=[]),
                    explanation=SafeExplanation(
                        root=(
                            "The planner could not produce a valid decision within "
                            "its attempt limit."
                        )
                    ),
                    missing_evidence=[],
                    reason=Reason.unsafe_to_repair,
                    schema_version="radarr-repair/v2",
                )
            ),
            "used_fallback": True,
        }
