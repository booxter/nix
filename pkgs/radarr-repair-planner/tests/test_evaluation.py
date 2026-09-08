from __future__ import annotations

import json
from pathlib import Path

from radarr_repair_planner.case_models import RepairCaseV1
from radarr_repair_planner.contracts import decode_decision
from radarr_repair_planner.decision_models import RepairDecisionV1
from radarr_repair_planner.evaluation import (
    EvaluationCase,
    EvaluationSettings,
    ExpectedJoin,
    ExpectedManualImport,
    ExpectedNoRepair,
    evaluate_outcome,
    load_evaluation_cases,
    run_evaluation,
)
from radarr_repair_planner.evaluation_cli import main
from radarr_repair_planner.ollama_model import MODEL_NAME, OllamaSettings
from radarr_repair_planner.planning import PlanningGraph, PlanningOutcome


def matching_decision(evaluation_case: EvaluationCase) -> RepairDecisionV1:
    expected = evaluation_case.spec.expected
    value: dict[str, object] = {
        "schema_version": "radarr-repair/v1",
        "case_id": evaluation_case.repair_case.case_id.root,
        "action": expected.action,
        "evidence_refs": [],
        "explanation": "Synthetic evaluation response.",
    }
    if isinstance(expected, ExpectedNoRepair):
        value.update(
            reason=expected.allowed_reasons[0].value,
            missing_evidence=[],
        )
    elif isinstance(expected, ExpectedJoin):
        value.update(
            capability_id=expected.capability_id,
            ordered_file_ids=expected.ordered_file_ids,
        )
    elif isinstance(expected, ExpectedManualImport):
        value.update(
            capability_id=expected.capability_id,
            file_id=expected.file_id,
        )
    return decode_decision(json.dumps(value).encode())


class ExpectedDecisionModel:
    def __init__(self) -> None:
        self.decisions = {
            evaluation_case.repair_case.case_id.root: matching_decision(evaluation_case)
            for evaluation_case in load_evaluation_cases()
        }

    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
    ) -> RepairDecisionV1:
        del system_instruction
        return self.decisions[repair_case.case_id.root]


class AlwaysNoRepairModel:
    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
    ) -> RepairDecisionV1:
        del system_instruction
        value = {
            "schema_version": "radarr-repair/v1",
            "case_id": repair_case.case_id.root,
            "action": "no_repair",
            "reason": "unsafe_to_repair",
            "missing_evidence": [],
            "evidence_refs": [],
            "explanation": "Synthetic abstention.",
        }
        return decode_decision(json.dumps(value).encode())


def settings(runs: int = 1) -> EvaluationSettings:
    return EvaluationSettings(
        model=MODEL_NAME,
        context_tokens=32768,
        output_tokens=4096,
        reasoning=True,
        timeout_seconds=5,
        runs=runs,
    )


def test_corpus_contains_review_cases_without_mutating_bases() -> None:
    cases = load_evaluation_cases()

    assert {evaluation_case.spec.name for evaluation_case in cases} == {
        "ambiguous_part_order",
        "clear_ordered_join",
        "episodic_release_with_join_pool",
        "incompatible_parts",
        "missing_movie_identity",
        "poorly_named_manual_import",
        "raw_bluray",
        "single_file_without_capability",
        "untrusted_filename_instruction",
    }
    clear_join = next(case for case in cases if case.spec.name == "clear_ordered_join")
    assert clear_join.repair_case.files[0].path_components[-1].root == "Example.Movie.2024.CD1.mkv"


async def test_matching_decisions_pass_the_corpus() -> None:
    report = await run_evaluation(PlanningGraph(ExpectedDecisionModel()), settings(runs=2))

    assert report.passed, [
        (result.case_name, result.violations) for result in report.results if not result.passed
    ]
    assert len(report.results) == 18
    assert all(result.passed for result in report.results)
    assert all(result.attempts == 1 for result in report.results)
    assert all(result.attempt_errors == [] for result in report.results)


def test_wrong_join_order_is_reported() -> None:
    evaluation_case = next(
        case for case in load_evaluation_cases() if case.spec.name == "clear_ordered_join"
    )
    decision = matching_decision(evaluation_case)
    decision.root.ordered_file_ids.reverse()

    result = evaluate_outcome(
        evaluation_case,
        1,
        PlanningOutcome(decision=decision, attempts=1, used_fallback=False),
    )

    assert not result.passed
    assert "join selected the wrong files or order" in result.violations


def test_fallback_is_never_counted_as_success() -> None:
    evaluation_case = next(
        case
        for case in load_evaluation_cases()
        if case.spec.name == "single_file_without_capability"
    )

    result = evaluate_outcome(
        evaluation_case,
        1,
        PlanningOutcome(
            decision=matching_decision(evaluation_case),
            attempts=2,
            used_fallback=True,
            attempt_errors=("attempt 1: HTTP 403", "attempt 2: HTTP 403"),
        ),
    )

    assert not result.passed
    assert "planner exhausted its attempts" in result.violations
    assert result.attempt_errors == ["attempt 1: HTTP 403", "attempt 2: HTTP 403"]


def expected_model_factory(settings: OllamaSettings) -> ExpectedDecisionModel:
    del settings
    return ExpectedDecisionModel()


def no_repair_model_factory(settings: OllamaSettings) -> AlwaysNoRepairModel:
    del settings
    return AlwaysNoRepairModel()


def cli_arguments(output: Path) -> list[str]:
    return [
        "--ollama-url",
        "https://frame:11434",
        "--ca-file",
        "ca.pem",
        "--client-cert-file",
        "client.pem",
        "--client-key-file",
        "client-key.pem",
        "--context-tokens",
        "32768",
        "--output-tokens",
        "4096",
        "--reasoning",
        "enabled",
        "--timeout-seconds",
        "5",
        "--output",
        str(output),
    ]


def test_cli_writes_passing_report(tmp_path: Path) -> None:
    output = tmp_path / "report.json"

    result = main(cli_arguments(output), model_factory=expected_model_factory)

    report = json.loads(output.read_bytes())
    assert result == 0
    assert report["passed"] is True
    assert report["settings"]["model"] == MODEL_NAME


def test_cli_returns_one_for_failed_expectations(tmp_path: Path) -> None:
    output = tmp_path / "report.json"

    result = main(cli_arguments(output), model_factory=no_repair_model_factory)

    report = json.loads(output.read_bytes())
    assert result == 1
    assert report["passed"] is False
