from __future__ import annotations

import json
import os
from collections.abc import Sequence
from pathlib import Path

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

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v3/examples"


class ScriptedDecisionModel:
    def __init__(self, steps: Sequence[RepairDecisionV3 | Exception]) -> None:
        self.steps = list(steps)
        self.calls: list[tuple[str, RepairCaseV3, tuple[DecisionViolation, ...]]] = []

    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV3,
        correction: tuple[DecisionViolation, ...],
    ) -> RepairDecisionV3:
        self.calls.append((system_instruction, repair_case, correction))
        step = self.steps.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


def repair_case(name: str = "repair-case-joinable.json") -> RepairCaseV3:
    return decode_case((FIXTURES / name).read_bytes())


def repair_decision(name: str = "repair-decision-join.json") -> RepairDecisionV3:
    return decode_decision((FIXTURES / name).read_bytes())


async def test_planner_returns_valid_model_decision() -> None:
    expected = repair_decision()
    model = ScriptedDecisionModel([expected])

    actual = await Planner(model).plan(repair_case())

    assert actual == expected
    assert len(model.calls) == 1
    assert model.calls[0][0] == SYSTEM_INSTRUCTION
    assert model.calls[0][2] == ()


async def test_planner_reports_successful_attempt() -> None:
    model = ScriptedDecisionModel([repair_decision()])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.attempts == 1
    assert not outcome.used_fallback
    assert outcome.attempt_errors == ()


async def test_planner_retries_one_expected_failure() -> None:
    expected = repair_decision()
    model = ScriptedDecisionModel([DecisionModelError("unavailable"), expected])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.decision == expected
    assert outcome.attempt_errors == ("attempt 1: unavailable",)
    assert len(model.calls) == 2
    assert model.calls[1][2] == ()


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
    wrong.root.case_id.root = "sha256:" + "0" * 64
    model = ScriptedDecisionModel([wrong, wrong])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert json.loads(encode_decision(outcome.decision))["action"] == "no_repair"
    assert outcome.attempt_errors == (
        "attempt 1: decision case_id does not match the case",
        "attempt 2: decision case_id does not match the case",
    )
    assert len(model.calls) == 2
    assert model.calls[1][2] == (
        DecisionViolation(
            code=ViolationCode.CASE_ID_MISMATCH,
            path=("case_id",),
            rejected_values=("sha256:" + "0" * 64,),
            allowed_values=(repair_case().case_id.root,),
        ),
    )


async def test_planner_passes_model_rejection_to_retry() -> None:
    violation = DecisionViolation(ViolationCode.INVALID_JSON, ())
    expected = repair_decision()
    model = ScriptedDecisionModel([DecisionModelError("invalid response", (violation,)), expected])

    outcome = await Planner(model).plan_with_outcome(repair_case())

    assert outcome.decision == expected
    assert model.calls[0][2] == ()
    assert model.calls[1][2] == (violation,)


async def test_planner_retries_invalid_structured_output_then_falls_back() -> None:
    invalid = repair_decision()
    invalid.root.case_id.root = "invalid"
    model = ScriptedDecisionModel([invalid, invalid])

    result = await Planner(model).plan(repair_case())

    assert json.loads(encode_decision(result))["action"] == "no_repair"
    assert len(model.calls) == 2


async def test_planner_revalidates_input_before_calling_model() -> None:
    case = repair_case()
    case.schema_version = "unsupported"  # type: ignore[assignment]
    model = ScriptedDecisionModel([repair_decision()])

    with pytest.raises(ContractError, match="contract validation failed"):
        await Planner(model).plan(case)

    assert model.calls == []


async def test_planner_does_not_hide_programming_errors() -> None:
    model = ScriptedDecisionModel([RuntimeError("bug")])

    with pytest.raises(RuntimeError, match="bug"):
        await Planner(model).plan(repair_case())
