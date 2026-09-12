from __future__ import annotations

import json
from pathlib import Path

import pytest
from radarr_repair_planner.case_models import RepairCaseV1
from radarr_repair_planner.contracts import decode_decision
from radarr_repair_planner.decision_models import RepairDecisionV1
from radarr_repair_planner.decision_validation import DecisionViolation
from radarr_repair_planner.evaluation import (
    EvaluationCase,
    EvaluationDataError,
    ExpectedJoin,
    ExpectedManualImport,
    ExpectedNoRepair,
    OllamaEvaluationSettings,
    _validate_expected_capability,
    evaluate_outcome,
    load_evaluation_cases,
    run_evaluation,
)
from radarr_repair_planner.evaluation_cli import main
from radarr_repair_planner.ollama_model import MODEL_NAME, OllamaSettings
from radarr_repair_planner.openrouter_model import OpenRouterSettings
from radarr_repair_planner.planning import PlanningGraph, PlanningOutcome
from radarr_repair_planner.tracing import TraceSink


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
        correction: tuple[DecisionViolation, ...],
    ) -> RepairDecisionV1:
        del system_instruction, correction
        return self.decisions[repair_case.case_id.root]


class CloseableExpectedDecisionModel(ExpectedDecisionModel):
    def __init__(self) -> None:
        super().__init__()
        self.closed = False

    async def close(self) -> None:
        self.closed = True


class AlwaysNoRepairModel:
    async def decide(
        self,
        system_instruction: str,
        repair_case: RepairCaseV1,
        correction: tuple[DecisionViolation, ...],
    ) -> RepairDecisionV1:
        del system_instruction, correction
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


def settings(runs: int = 1, case: str | None = None) -> OllamaEvaluationSettings:
    return OllamaEvaluationSettings(
        model=MODEL_NAME,
        context_tokens=32768,
        output_tokens=4096,
        reasoning=True,
        timeout_seconds=5,
        runs=runs,
        case=case,
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
        "real_anime_season",
        "real_double_exposure_raw_bluray",
        "real_expendables_manual_import",
        "real_grafenberg_ambiguous",
        "real_pandoras_mirror_raw_bluray",
        "real_portrait_manual_import",
        "real_traci_manual_import",
        "real_xconfessions_raw_bluray",
        "single_file_without_capability",
        "untrusted_filename_instruction",
    }
    clear_join = next(case for case in cases if case.spec.name == "clear_ordered_join")
    assert clear_join.repair_case.files[0].path_components[-1].root == "Example.Movie.2024.CD1.mkv"


def test_corpus_rejects_unavailable_expected_capability() -> None:
    evaluation_case = next(
        case for case in load_evaluation_cases() if case.spec.name == "clear_ordered_join"
    )
    expected = evaluation_case.spec.expected.model_copy(
        update={"capability_id": "capability:" + "0" * 64}
    )
    spec = evaluation_case.spec.model_copy(update={"expected": expected})

    with pytest.raises(EvaluationDataError, match="unavailable capability"):
        _validate_expected_capability(spec, evaluation_case.repair_case)


def test_corpus_rejects_expected_capability_with_wrong_action() -> None:
    evaluation_case = next(
        case for case in load_evaluation_cases() if case.spec.name == "clear_ordered_join"
    )
    assert isinstance(evaluation_case.spec.expected, ExpectedJoin)
    expected = ExpectedManualImport(
        action="manual_import_file_v1",
        capability_id=evaluation_case.spec.expected.capability_id,
        file_id="file:" + "0" * 64,
    )
    spec = evaluation_case.spec.model_copy(update={"expected": expected})

    with pytest.raises(EvaluationDataError, match="wrong capability action"):
        _validate_expected_capability(spec, evaluation_case.repair_case)


def test_corpus_rejects_wrong_expected_manual_import_file() -> None:
    evaluation_case = next(
        case for case in load_evaluation_cases() if case.spec.name == "real_portrait_manual_import"
    )
    expected = evaluation_case.spec.expected.model_copy(update={"file_id": "file:" + "0" * 64})
    spec = evaluation_case.spec.model_copy(update={"expected": expected})

    with pytest.raises(EvaluationDataError, match="wrong manual-import file"):
        _validate_expected_capability(spec, evaluation_case.repair_case)


def test_corpus_rejects_unavailable_expected_join_file() -> None:
    evaluation_case = next(
        case for case in load_evaluation_cases() if case.spec.name == "clear_ordered_join"
    )
    assert isinstance(evaluation_case.spec.expected, ExpectedJoin)
    expected = evaluation_case.spec.expected.model_copy(
        update={
            "ordered_file_ids": [
                *evaluation_case.spec.expected.ordered_file_ids,
                "file:" + "0" * 64,
            ]
        }
    )
    spec = evaluation_case.spec.model_copy(update={"expected": expected})

    with pytest.raises(EvaluationDataError, match="unavailable join files"):
        _validate_expected_capability(spec, evaluation_case.repair_case)


async def test_matching_decisions_pass_the_corpus() -> None:
    report = await run_evaluation(PlanningGraph(ExpectedDecisionModel()), settings(runs=2))

    assert report.passed, [
        (result.case_name, result.violations) for result in report.results if not result.passed
    ]
    assert len(report.results) == 34
    assert all(result.passed for result in report.results)
    assert all(result.attempts == 1 for result in report.results)
    assert all(result.attempt_errors == [] for result in report.results)


async def test_evaluation_can_select_one_case() -> None:
    report = await run_evaluation(
        PlanningGraph(ExpectedDecisionModel()),
        settings(case="clear_ordered_join"),
    )

    assert report.passed
    assert [result.case_name for result in report.results] == ["clear_ordered_join"]


async def test_evaluation_rejects_unknown_case() -> None:
    with pytest.raises(ValueError, match="unknown evaluation case: missing"):
        await run_evaluation(
            PlanningGraph(ExpectedDecisionModel()),
            settings(case="missing"),
        )


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


def expected_model_factory(
    settings: OllamaSettings | OpenRouterSettings,
    trace_sink: TraceSink | None,
) -> ExpectedDecisionModel:
    del settings, trace_sink
    return ExpectedDecisionModel()


def no_repair_model_factory(
    settings: OllamaSettings | OpenRouterSettings,
    trace_sink: TraceSink | None,
) -> AlwaysNoRepairModel:
    del settings, trace_sink
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


def cloud_cli_arguments(output: Path, api_key_file: Path) -> list[str]:
    return [
        "--ollama-url",
        "https://ollama.com",
        "--ollama-api-key-file",
        str(api_key_file),
        "--context-tokens",
        "32768",
        "--output-tokens",
        "4096",
        "--reasoning",
        "disabled",
        "--timeout-seconds",
        "5",
        "--output",
        str(output),
    ]


def openrouter_cli_arguments(output: Path, api_key_file: Path) -> list[str]:
    return [
        "--backend",
        "openrouter",
        "--model",
        "openai/gpt-5.6-terra",
        "--openrouter-provider",
        "OpenAI",
        "--openrouter-api-key-file",
        str(api_key_file),
        "--output-tokens",
        "4096",
        "--reasoning",
        "high",
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
    assert report["settings"]["backend"] == "ollama"
    assert report["settings"]["model"] == MODEL_NAME


def test_cli_selects_one_case(tmp_path: Path) -> None:
    output = tmp_path / "report.json"

    result = main(
        [*cli_arguments(output), "--case", "clear_ordered_join"],
        model_factory=expected_model_factory,
    )

    report = json.loads(output.read_bytes())
    assert result == 0
    assert report["settings"]["case"] == "clear_ordered_join"
    assert [item["case_name"] for item in report["results"]] == ["clear_ordered_join"]


def test_cli_selects_model(tmp_path: Path) -> None:
    output = tmp_path / "report.json"
    selected_models: list[str] = []

    def recording_model_factory(
        settings: OllamaSettings | OpenRouterSettings,
        trace_sink: TraceSink | None,
    ) -> ExpectedDecisionModel:
        del trace_sink
        assert isinstance(settings, OllamaSettings)
        selected_models.append(settings.model)
        return ExpectedDecisionModel()

    result = main(
        [*cli_arguments(output), "--model", "granite4:32b-a9b-h"],
        model_factory=recording_model_factory,
    )

    report = json.loads(output.read_bytes())
    assert result == 0
    assert selected_models == ["granite4:32b-a9b-h"]
    assert report["settings"]["model"] == "granite4:32b-a9b-h"


def test_cli_selects_api_key_file_without_recording_it(tmp_path: Path) -> None:
    output = tmp_path / "report.json"
    api_key_file = tmp_path / "ollama-api-key"
    selected_settings: list[OllamaSettings] = []

    def recording_model_factory(
        settings: OllamaSettings | OpenRouterSettings,
        trace_sink: TraceSink | None,
    ) -> ExpectedDecisionModel:
        del trace_sink
        assert isinstance(settings, OllamaSettings)
        selected_settings.append(settings)
        return ExpectedDecisionModel()

    result = main(
        cloud_cli_arguments(output, api_key_file),
        model_factory=recording_model_factory,
    )

    report = output.read_text(encoding="utf-8")
    assert result == 0
    assert selected_settings[0].api_key_file == api_key_file
    assert selected_settings[0].ca_file is None
    assert selected_settings[0].client_cert_file is None
    assert selected_settings[0].client_key_file is None
    assert str(api_key_file) not in report


def test_cli_selects_openrouter_without_recording_its_key(tmp_path: Path) -> None:
    output = tmp_path / "report.json"
    api_key_file = tmp_path / "openrouter-api-key"
    selected_settings: list[OpenRouterSettings] = []
    selected_models: list[CloseableExpectedDecisionModel] = []

    def recording_model_factory(
        settings: OllamaSettings | OpenRouterSettings,
        trace_sink: TraceSink | None,
    ) -> CloseableExpectedDecisionModel:
        del trace_sink
        assert isinstance(settings, OpenRouterSettings)
        selected_settings.append(settings)
        model = CloseableExpectedDecisionModel()
        selected_models.append(model)
        return model

    result = main(
        openrouter_cli_arguments(output, api_key_file),
        model_factory=recording_model_factory,
    )

    report = json.loads(output.read_bytes())
    assert result == 0
    assert selected_settings == [
        OpenRouterSettings(
            api_key_file=api_key_file,
            model="openai/gpt-5.6-terra",
            provider="OpenAI",
            output_tokens=4096,
            reasoning_effort="high",
            timeout_seconds=5,
        )
    ]
    assert report["settings"] == {
        "backend": "openrouter",
        "model": "openai/gpt-5.6-terra",
        "provider": "OpenAI",
        "output_tokens": 4096,
        "reasoning_effort": "high",
        "timeout_seconds": 5.0,
        "runs": 1,
        "case": None,
    }
    assert str(api_key_file) not in output.read_text(encoding="utf-8")
    assert selected_models[0].closed


@pytest.mark.parametrize(
    ("backend", "arguments", "message"),
    [
        ("ollama", ["--reasoning", "high"], "enabled or disabled"),
        ("openrouter", ["--ollama-url", "https://frame:11434"], "cannot be used"),
    ],
)
def test_cli_rejects_backend_specific_options(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    backend: str,
    arguments: list[str],
    message: str,
) -> None:
    output = tmp_path / "report.json"
    api_key_file = tmp_path / "openrouter-api-key"
    base = (
        cli_arguments(output)
        if backend == "ollama"
        else openrouter_cli_arguments(output, api_key_file)
    )

    result = main([*base, *arguments], model_factory=expected_model_factory)

    assert result == 2
    assert message in capsys.readouterr().err
    assert not output.exists()


def test_cli_creates_private_trace_file(tmp_path: Path) -> None:
    output = tmp_path / "report.json"
    trace = tmp_path / "trace.jsonl"

    result = main(
        [*cli_arguments(output), "--trace-output", str(trace)],
        model_factory=expected_model_factory,
    )

    assert result == 0
    assert trace.read_bytes() == b""
    assert trace.stat().st_mode & 0o777 == 0o600


def test_cli_returns_one_for_failed_expectations(tmp_path: Path) -> None:
    output = tmp_path / "report.json"

    result = main(cli_arguments(output), model_factory=no_repair_model_factory)

    report = json.loads(output.read_bytes())
    assert result == 1
    assert report["passed"] is False
