from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol, TypedDict, cast

from langgraph.graph import END, START, StateGraph
from langgraph.graph.state import CompiledStateGraph

from .case_models import RepairCaseV1
from .contracts import ContractError, decode_case, decode_decision, encode_case, encode_decision
from .decision_models import (
    EvidenceRefs,
    NoRepair,
    Reason,
    RepairDecisionV1,
    SafeExplanation,
    Sha256Id,
)
from .prompt import SYSTEM_INSTRUCTION

ATTEMPT_LIMIT = 2


class DecisionModelError(Exception):
    """An expected model call or structured-output failure."""


class DecisionModel(Protocol):
    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
    ) -> RepairDecisionV1: ...


class PlanningState(TypedDict):
    repair_case: RepairCaseV1
    attempts: int
    decision: RepairDecisionV1 | None
    used_fallback: bool


class PlanningUpdate(TypedDict, total=False):
    attempts: int
    decision: RepairDecisionV1 | None
    used_fallback: bool


Route = Literal["done", "retry", "fallback"]


@dataclass(frozen=True)
class PlanningOutcome:
    decision: RepairDecisionV1
    attempts: int
    used_fallback: bool


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

    async def plan(self, repair_case: RepairCaseV1) -> RepairDecisionV1:
        return (await self.plan_with_outcome(repair_case)).decision

    async def plan_with_outcome(self, repair_case: RepairCaseV1) -> PlanningOutcome:
        validated_case = decode_case(encode_case(repair_case))
        result = cast(
            PlanningState,
            await self._graph.ainvoke(
                {
                    "repair_case": validated_case,
                    "attempts": 0,
                    "decision": None,
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
        )

    async def _attempt(self, state: PlanningState) -> PlanningUpdate:
        attempts = state["attempts"] + 1
        try:
            proposed = await self._model.decide(
                SYSTEM_INSTRUCTION,
                state["repair_case"],
            )
            decision = decode_decision(encode_decision(proposed))
        except (ContractError, DecisionModelError):
            return {"attempts": attempts, "decision": None}
        if decision.root.case_id.root != state["repair_case"].case_id.root:
            return {"attempts": attempts, "decision": None}
        return {"attempts": attempts, "decision": decision}

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
            "decision": RepairDecisionV1(
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
                    schema_version="radarr-repair/v1",
                )
            ),
            "used_fallback": True,
        }
