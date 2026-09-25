from __future__ import annotations

import json
import os
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import pytest
from media_repair_planner.case_models import RepairCaseV3
from media_repair_planner.contracts import (
    ContractError,
    decode_case,
    decode_decision,
    encode_decision,
)
from media_repair_planner.decision_models import RepairDecisionV3
from media_repair_planner.decision_validation_core import DecisionViolation, ViolationCode
from media_repair_planner.planning import DecisionModelError, Planner
from media_repair_planner.prompt import SYSTEM_INSTRUCTION
from media_repair_planner.radarr_projection import project_case
from media_repair_planner.structured_model import StructuredModelResponse
from pydantic import BaseModel

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v3/examples"


class ScriptedDecisionModel:
    def __init__(self, steps: Sequence[str | Exception]) -> None:
        self.steps = list(steps)
        self.calls: list[tuple[str, str, dict[str, Any], str, tuple[DecisionViolation, ...]]] = []

    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> StructuredModelResponse:
        assert decision_model is RepairDecisionV3
        self.calls.append((system_instruction, case_content, decision_schema, case_id, correction))
        step = self.steps.pop(0)
        if isinstance(step, Exception):
            raise step
        return StructuredModelResponse(step, "Scripted")


def repair_case(name: str = "repair-case-joinable.json") -> RepairCaseV3:
    return decode_case((FIXTURES / name).read_bytes())


def repair_decision(name: str = "repair-decision-join.json") -> RepairDecisionV3:
    return decode_decision((FIXTURES / name).read_bytes())


def model_output(decision: RepairDecisionV3) -> str:
    return encode_decision(decision).decode()


async def test_planner_returns_valid_model_decision() -> None:
    expected = repair_decision()
    model = ScriptedDecisionModel([model_output(expected)])

    actual = await Planner(model).plan(repair_case())

    assert actual == expected
    assert len(model.calls) == 1
    assert model.calls[0][0] == SYSTEM_INSTRUCTION
    assert model.calls[0][1] == project_case(repair_case()).case_content
    assert model.calls[0][4] == ()


async def test_planner_reports_successful_attempt() -> None:
    model = ScriptedDecisionModel([model_output(repair_decision())])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.attempts == 1
    assert not outcome.used_fallback
    assert outcome.attempt_errors == ()


async def test_planner_retries_one_expected_failure() -> None:
    expected = repair_decision()
    model = ScriptedDecisionModel([DecisionModelError("unavailable"), model_output(expected)])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.decision == expected
    assert outcome.attempt_errors == ("attempt 1: unavailable",)
    assert len(model.calls) == 2
    assert model.calls[1][4] == ()


async def test_planner_falls_back_after_attempt_limit() -> None:
    model = ScriptedDecisionModel(
        [
            DecisionModelError("first failure"),
            DecisionModelError("second failure"),
        ]
    )
    case = repair_case()

    result = await Planner(model).plan(case)
    value = json.loads(encode_decision(result))

    assert len(model.calls) == 2
    assert value["action"] == "no_repair"
    assert value["case_id"] == case.case_id.root
    assert value["reason"] == "unsafe_to_repair"
    assert value["evidence_refs"] == []


async def test_planner_reports_fallback() -> None:
    model = ScriptedDecisionModel(
        [DecisionModelError("first failure"), DecisionModelError("second failure")]
    )

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.attempts == 2
    assert outcome.used_fallback
    assert outcome.attempt_errors == (
        "attempt 1: first failure",
        "attempt 2: second failure",
    )


async def test_planner_retries_wrong_case_id_then_falls_back() -> None:
    wrong = repair_decision()
    wrong_case_id = "sha256:" + "f" * 64
    wrong.root.case_id.root = wrong_case_id
    model = ScriptedDecisionModel([model_output(wrong), model_output(wrong)])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert json.loads(encode_decision(outcome.decision))["action"] == "no_repair"
    assert outcome.attempt_errors == (
        "attempt 1: decision case_id does not match the case",
        "attempt 2: decision case_id does not match the case",
    )
    assert len(model.calls) == 2
    assert model.calls[1][4] == (
        DecisionViolation(
            code=ViolationCode.CASE_ID_MISMATCH,
            path=("case_id",),
            rejected_values=(wrong_case_id,),
            allowed_values=("sha256:" + "0" * 64,),
        ),
    )


async def test_planner_passes_model_rejection_to_retry() -> None:
    violation = DecisionViolation(ViolationCode.INVALID_JSON, ())
    expected = repair_decision()
    model = ScriptedDecisionModel(
        [DecisionModelError("invalid response", (violation,)), model_output(expected)]
    )

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.decision == expected
    assert model.calls[0][4] == ()
    assert model.calls[1][4] == (violation,)


async def test_planner_retries_invalid_structured_output_then_falls_back() -> None:
    invalid = json.loads(model_output(repair_decision()))
    invalid["case_id"] = "invalid"
    output = json.dumps(invalid)
    model = ScriptedDecisionModel([output, output])

    result = await Planner(model).plan(repair_case())

    assert json.loads(encode_decision(result))["action"] == "no_repair"
    assert len(model.calls) == 2


async def test_planner_revalidates_input_before_calling_model() -> None:
    case = repair_case()
    case.schema_version = "unsupported"  # type: ignore[assignment]
    model = ScriptedDecisionModel([model_output(repair_decision())])

    with pytest.raises(ContractError, match="contract validation failed"):
        await Planner(model).plan(case)

    assert model.calls == []


async def test_planner_does_not_hide_programming_errors() -> None:
    model = ScriptedDecisionModel([RuntimeError("bug")])

    with pytest.raises(RuntimeError, match="bug"):
        await Planner(model).plan(repair_case())
