from __future__ import annotations

import json
import os
from collections.abc import Sequence
from pathlib import Path

import pytest
from radarr_repair_planner.case_models import RepairCaseV1
from radarr_repair_planner.contracts import (
    ContractError,
    decode_case,
    decode_decision,
    encode_decision,
)
from radarr_repair_planner.decision_models import RepairDecisionV1
from radarr_repair_planner.planning import DecisionModelError, PlanningGraph
from radarr_repair_planner.prompt import SYSTEM_INSTRUCTION

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v1/examples"


class ScriptedDecisionModel:
    def __init__(self, steps: Sequence[RepairDecisionV1 | Exception]) -> None:
        self.steps = list(steps)
        self.calls: list[tuple[str, RepairCaseV1]] = []

    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
    ) -> RepairDecisionV1:
        self.calls.append((system_instruction, repair_case))
        step = self.steps.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


def repair_case(name: str = "repair-case-joinable.json") -> RepairCaseV1:
    return decode_case((FIXTURES / name).read_bytes())


def repair_decision(name: str = "repair-decision-join.json") -> RepairDecisionV1:
    return decode_decision((FIXTURES / name).read_bytes())


async def test_graph_returns_valid_model_decision() -> None:
    expected = repair_decision()
    model = ScriptedDecisionModel([expected])

    actual = await PlanningGraph(model).plan(repair_case())

    assert actual == expected
    assert len(model.calls) == 1
    assert model.calls[0][0] == SYSTEM_INSTRUCTION


async def test_graph_retries_one_expected_failure() -> None:
    expected = repair_decision()
    model = ScriptedDecisionModel([DecisionModelError("unavailable"), expected])

    actual = await PlanningGraph(model).plan(repair_case())

    assert actual == expected
    assert len(model.calls) == 2


async def test_graph_falls_back_after_attempt_limit() -> None:
    model = ScriptedDecisionModel(
        [
            DecisionModelError("first failure"),
            DecisionModelError("second failure"),
        ]
    )
    case = repair_case()

    result = await PlanningGraph(model).plan(case)
    value = json.loads(encode_decision(result))

    assert len(model.calls) == 2
    assert value["action"] == "no_repair"
    assert value["case_id"] == case.case_id.root
    assert value["reason"] == "unsafe_to_repair"
    assert value["evidence_refs"] == []


async def test_graph_retries_wrong_case_id_then_falls_back() -> None:
    wrong = repair_decision()
    wrong.root.case_id.root = "sha256:" + "0" * 64
    model = ScriptedDecisionModel([wrong, wrong])

    result = await PlanningGraph(model).plan(repair_case())

    assert json.loads(encode_decision(result))["action"] == "no_repair"
    assert len(model.calls) == 2


async def test_graph_retries_invalid_structured_output_then_falls_back() -> None:
    invalid = repair_decision()
    invalid.root.case_id.root = "invalid"
    model = ScriptedDecisionModel([invalid, invalid])

    result = await PlanningGraph(model).plan(repair_case())

    assert json.loads(encode_decision(result))["action"] == "no_repair"
    assert len(model.calls) == 2


async def test_graph_revalidates_input_before_calling_model() -> None:
    case = repair_case()
    case.schema_version = "unsupported"  # type: ignore[assignment]
    model = ScriptedDecisionModel([repair_decision()])

    with pytest.raises(ContractError, match="contract validation failed"):
        await PlanningGraph(model).plan(case)

    assert model.calls == []


async def test_graph_does_not_hide_programming_errors() -> None:
    model = ScriptedDecisionModel([RuntimeError("bug")])

    with pytest.raises(RuntimeError, match="bug"):
        await PlanningGraph(model).plan(repair_case())
