from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import httpx
import pytest
from media_repair_planner.api import ContractEndpoint, create_app
from media_repair_planner.case_models import RepairCaseV3
from media_repair_planner.decision_models import RepairDecisionV3
from media_repair_planner.decision_validation import DecisionViolation, ViolationCode
from media_repair_planner.evaluation_runtime import OpenRouterEvaluationSettings
from media_repair_planner.lidarr_case_models import LidarrRepairCaseV3
from media_repair_planner.lidarr_contracts import (
    ContractError,
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)
from media_repair_planner.lidarr_decision_models import LidarrRepairDecisionV3
from media_repair_planner.lidarr_evaluation import (
    CorpusCase,
    LidarrEvaluationDataError,
    evaluate_outcome,
    load_cases,
    run_evaluation,
)
from media_repair_planner.lidarr_evaluation_cli import main as evaluation_main
from media_repair_planner.lidarr_planning import LidarrPlanner
from media_repair_planner.lidarr_projection import project_case
from media_repair_planner.lidarr_validation import (
    validate_decision_for_case,
    validate_decision_object,
)
from media_repair_planner.planning_core import PlanningOutcome
from pydantic import BaseModel

CASE_ID = "sha256:" + "a" * 64


def case_value() -> dict[str, object]:
    artifacts = []
    assessments = []
    tracks = []
    for number, title in ((1, "First"), (2, "Second")):
        artifact_id = f"artifact:{number}"
        artifacts.append(
            {
                "artifact_id": artifact_id,
                "relative_path": f"{number:02d} - {title}.flac",
                "fingerprint": "sha256:" + str(number) * 64,
                "size_bytes": 1000 * number,
                "duration_ms": 180000 + number,
                "formats": ["flac"],
                "tags": [
                    {"name": "artist", "value": "Artist"},
                    {"name": "album", "value": "Album"},
                    {"name": "title", "value": title},
                    {"name": "track", "value": str(number)},
                ],
                "streams": [
                    {
                        "kind": "audio",
                        "codec": "flac",
                        "sample_rate_hz": 44100,
                        "channels": 2,
                        "bit_rate_bps": None,
                    }
                ],
            }
        )
        assessments.append(
            {
                "artifact_id": artifact_id,
                "album_id": 3,
                "release_id": 4,
                "track_ids": [number + 4],
                "tag_title": title,
                "tag_artist": "Artist",
                "tag_album": "Album",
                "tag_track_numbers": [number],
                "rejections": [],
            }
        )
        tracks.append(
            {
                "track_id": number + 4,
                "release_id": 4,
                "number": str(number),
                "absolute_number": number,
                "medium_number": 1,
                "title": title,
                "duration_ms": 180000 + number,
                "has_file": False,
            }
        )
    return {
        "schema_version": "lidarr-repair/v3",
        "case_id": CASE_ID,
        "observed_at": "2026-09-21T12:00:00Z",
        "queue": {
            "queue_id": 1,
            "title": "Artist - Album",
            "download_ref": "download:one",
            "messages": ["Found archive file, might need to be extracted"],
        },
        "album": {
            "album_id": 3,
            "artist_id": 2,
            "artist": "Artist",
            "title": "Album",
            "monitored": True,
        },
        "releases": [
            {
                "release_id": 4,
                "foreign_release_id": "release",
                "title": "Album",
                "disambiguation": "",
                "format": "Album",
                "countries": [],
                "labels": [],
                "track_count": 2,
                "medium_count": 1,
                "monitored": True,
            }
        ],
        "tracks": tracks,
        "artifacts": artifacts,
        "assessments": assessments,
        "capabilities": [
            {
                "action": "import_missing_tracks_v1",
                "capability_id": "capability:one",
                "album_id": 3,
                "artifact_ids": ["artifact:1", "artifact:2"],
                "release_id": 4,
                "track_ids": [5, 6],
            }
        ],
    }


def decision_value(**changes: object) -> dict[str, object]:
    value: dict[str, object] = {
        "schema_version": "lidarr-repair/v3",
        "case_id": CASE_ID,
        "action": "import_missing_tracks_v1",
        "capability_id": "capability:one",
        "album_id": 3,
        "release_id": 4,
        "mappings": [
            {"artifact_id": "artifact:1", "track_id": 5},
            {"artifact_id": "artifact:2", "track_id": 6},
        ],
        "evidence_refs": ["artifact:1", "artifact:2"],
        "explanation": "Tags, numbering, and durations agree with the complete release.",
    }
    value.update(changes)
    return value


def repair_case() -> LidarrRepairCaseV3:
    return decode_case(json.dumps(case_value()).encode())


def repair_decision(**changes: object) -> LidarrRepairDecisionV3:
    return decode_decision(json.dumps(decision_value(**changes)).encode())


def model_decision_value(**changes: object) -> dict[str, object]:
    return decision_value(capability_id="capability:1", **changes)


class ScriptedModel:
    def __init__(self, outputs: list[str | Exception]) -> None:
        self.outputs = outputs
        self.calls: list[tuple[str, str, dict[str, Any], str, tuple[DecisionViolation, ...]]] = []

    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        decision_model: type[BaseModel],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> str:
        assert decision_model is LidarrRepairDecisionV3
        self.calls.append((system_instruction, case_content, decision_schema, case_id, correction))
        output = self.outputs.pop(0)
        if isinstance(output, Exception):
            raise output
        return output


async def test_lidarr_planner_returns_complete_mapping() -> None:
    expected = repair_decision()
    model = ScriptedModel([json.dumps(model_decision_value())])
    case = repair_case()

    outcome = await LidarrPlanner(model).plan_with_outcome(case)

    assert outcome.decision == expected
    assert outcome.attempts == 1
    assert not outcome.used_fallback
    assert model.calls[0][3] == CASE_ID
    assert model.calls[0][1] == project_case(case).case_content


async def test_lidarr_planner_returns_partial_mapping() -> None:
    expected = repair_decision(
        mappings=[{"artifact_id": "artifact:1", "track_id": 5}],
        evidence_refs=["artifact:1"],
    )
    model = ScriptedModel(
        [
            json.dumps(
                model_decision_value(
                    mappings=[{"artifact_id": "artifact:1", "track_id": 5}],
                    evidence_refs=["artifact:1"],
                )
            )
        ]
    )

    outcome = await LidarrPlanner(model).plan_with_outcome(repair_case())

    assert outcome.decision == expected
    assert outcome.attempts == 1
    assert not outcome.used_fallback


async def test_lidarr_planner_corrects_invalid_mapping_then_falls_back() -> None:
    invalid = json.dumps(
        model_decision_value(
            mappings=[
                {"artifact_id": "artifact:1", "track_id": 5},
                {"artifact_id": "artifact:1", "track_id": 5},
            ]
        )
    )
    model = ScriptedModel([invalid, invalid])

    outcome = await LidarrPlanner(model).plan_with_outcome(repair_case())

    assert outcome.used_fallback
    assert outcome.decision.root.action == "no_repair"
    assert outcome.decision.root.case_id.root == CASE_ID
    assert len(model.calls[1][4]) == 2
    assert all(item.code == ViolationCode.INVALID_FIELD for item in model.calls[1][4])


async def test_lidarr_planner_logs_bounded_fallback_evidence(
    caplog: pytest.LogCaptureFixture,
) -> None:
    invalid = json.dumps(
        model_decision_value(
            mappings=[
                {"artifact_id": "artifact:1", "track_id": 5},
                {"artifact_id": "artifact:1", "track_id": 5},
            ]
        )
    )
    model = ScriptedModel([invalid, invalid])

    decision = await LidarrPlanner(model).plan(repair_case())

    assert decision.root.action == "no_repair"
    assert len(caplog.records) == 1
    assert caplog.records[0].levelname == "WARNING"
    assert (
        caplog.records[0]
        .getMessage()
        .startswith(f"planner used fallback case_id={CASE_ID} attempts=2 errors=")
    )
    assert (
        "decision field does not satisfy the schema at mappings.artifact_id"
        in caplog.records[0].getMessage()
    )


async def test_lidarr_planner_corrects_malformed_output() -> None:
    model = ScriptedModel(["not JSON", json.dumps(model_decision_value())])

    outcome = await LidarrPlanner(model).plan_with_outcome(repair_case())

    assert not outcome.used_fallback
    assert model.calls[1][4][0].code == ViolationCode.INVALID_JSON


def test_lidarr_semantic_validation_rejects_unoffered_values() -> None:
    decision = repair_decision(
        case_id="sha256:" + "b" * 64,
        capability_id="capability:other",
        evidence_refs=["artifact:other"],
    )

    violations = validate_decision_for_case(repair_case(), decision)

    assert [item.code for item in violations] == [
        ViolationCode.CASE_ID_MISMATCH,
        ViolationCode.UNKNOWN_EVIDENCE,
        ViolationCode.UNKNOWN_CAPABILITY,
    ]


def test_lidarr_semantic_validation_rejects_album_and_release() -> None:
    decision = repair_decision(album_id=9, release_id=10)

    violations = validate_decision_for_case(repair_case(), decision)

    assert [item.path for item in violations] == [("album_id",), ("release_id",)]


def test_lidarr_semantic_validation_allows_unused_existing_track_artifact() -> None:
    value = case_value()
    tracks = value["tracks"]
    assert isinstance(tracks, list)
    assert isinstance(tracks[0], dict)
    tracks[0]["has_file"] = True
    capabilities = value["capabilities"]
    assert isinstance(capabilities, list)
    assert isinstance(capabilities[0], dict)
    capabilities[0]["track_ids"] = [6]
    repair_case = decode_case(json.dumps(value).encode())
    decision = repair_decision(
        mappings=[{"artifact_id": "artifact:2", "track_id": 6}],
    )

    assert validate_decision_for_case(repair_case, decision) == ()


def test_lidarr_semantic_validation_allows_partial_mapping() -> None:
    decision = repair_decision(
        mappings=[{"artifact_id": "artifact:1", "track_id": 5}],
        evidence_refs=["artifact:1"],
    )

    assert validate_decision_for_case(repair_case(), decision) == ()


def test_lidarr_no_repair_is_valid() -> None:
    decision = decode_decision(
        json.dumps(
            {
                "schema_version": "lidarr-repair/v3",
                "case_id": CASE_ID,
                "action": "no_repair",
                "reason": "ambiguous_tracks",
                "evidence_refs": ["artifact:1"],
                "explanation": "The two track mappings remain ambiguous.",
            }
        ).encode()
    )

    assert validate_decision_for_case(repair_case(), decision) == ()


def test_lidarr_contract_rejects_unknown_fields() -> None:
    value = case_value()
    value["private"] = "not allowed"
    try:
        decode_case(json.dumps(value).encode())
    except ContractError as error:
        assert "contract validation failed" in str(error)
    else:
        raise AssertionError("invalid contract was accepted")


def test_lidarr_object_validation_explains_missing_and_unknown_action() -> None:
    missing = validate_decision_object({})
    unknown = validate_decision_object({"action": "run_command"})

    assert missing[0].code == ViolationCode.MISSING_FIELD
    assert unknown[0].allowed_values == ("no_repair", "import_missing_tracks_v1")


class NeverRadarrPlanner:
    async def plan(self, repair_case: RepairCaseV3) -> RepairDecisionV3:
        del repair_case
        raise AssertionError("wrong endpoint")


class StaticLidarrPlanner:
    async def plan(self, repair_case: LidarrRepairCaseV3) -> LidarrRepairDecisionV3:
        assert repair_case.case_id.root == CASE_ID
        return repair_decision()


async def test_lidarr_endpoint_uses_shared_http_boundary() -> None:
    endpoint = ContractEndpoint(
        planner=StaticLidarrPlanner(),
        decode_case=decode_case,
        encode_decision=encode_decision,
    )
    app = create_app(
        NeverRadarrPlanner(),
        additional_endpoints={"/lidarr/v3/repair-plans": endpoint},
    )
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://planner") as client:
        response = await client.post(
            "/lidarr/v3/repair-plans",
            content=encode_case(repair_case()),
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 200
    assert decode_decision(response.content) == repair_decision()


def write_lidarr_case(directory: Path, value: dict[str, object] | None = None) -> Path:
    path = directory / ("a" * 64 + ".json")
    path.write_text(json.dumps(value or case_value()), encoding="utf-8")
    return path


def lidarr_evaluation_settings(case: str | None = None) -> OpenRouterEvaluationSettings:
    return OpenRouterEvaluationSettings(
        model="openai/gpt-5.6-sol",
        provider="OpenAI",
        output_tokens=4096,
        reasoning_effort="high",
        timeout_seconds=30,
        runs=1,
        case=case,
    )


def test_lidarr_review_corpus_loads_contract_cases(tmp_path: Path) -> None:
    write_lidarr_case(tmp_path)

    corpus = load_cases(tmp_path)

    assert len(corpus) == 1
    assert corpus[0].name == "a" * 64
    assert corpus[0].repair_case.case_id.root == CASE_ID


def test_lidarr_review_corpus_rejects_bad_identity(tmp_path: Path) -> None:
    value = case_value()
    value["case_id"] = "sha256:" + "b" * 64
    write_lidarr_case(tmp_path, value)

    with pytest.raises(LidarrEvaluationDataError, match="does not match"):
        load_cases(tmp_path)


async def test_lidarr_review_runs_structured_planner(tmp_path: Path) -> None:
    write_lidarr_case(tmp_path)
    model = ScriptedModel([json.dumps(model_decision_value())])

    report = await run_evaluation(
        LidarrPlanner(model),
        lidarr_evaluation_settings(),
        load_cases(tmp_path),
    )

    assert report.passed
    assert report.results[0].artist == "Artist"
    assert report.results[0].album == "Album"
    assert report.results[0].decision["action"] == "import_missing_tracks_v1"


async def test_lidarr_review_rejects_unknown_case(tmp_path: Path) -> None:
    write_lidarr_case(tmp_path)

    with pytest.raises(LidarrEvaluationDataError, match="unknown Lidarr evaluation case"):
        await run_evaluation(
            LidarrPlanner(ScriptedModel([])),
            lidarr_evaluation_settings(case="b" * 64),
            load_cases(tmp_path),
        )


def test_lidarr_review_marks_fallback_as_failed() -> None:
    corpus_case = CorpusCase(name="a" * 64, repair_case=repair_case())
    result = evaluate_outcome(
        corpus_case,
        1,
        PlanningOutcome(
            decision=decode_decision(
                json.dumps(
                    {
                        "schema_version": "lidarr-repair/v3",
                        "case_id": CASE_ID,
                        "action": "no_repair",
                        "reason": "unsafe_to_repair",
                        "evidence_refs": [],
                        "explanation": "The planner exhausted its attempts.",
                    }
                ).encode()
            ),
            attempts=2,
            used_fallback=True,
            attempt_errors=("attempt 1: invalid", "attempt 2: invalid"),
        ),
    )

    assert not result.passed
    assert result.violations == ["planner exhausted its attempts"]


def test_lidarr_review_cli_writes_openrouter_report(tmp_path: Path) -> None:
    write_lidarr_case(tmp_path)
    output = tmp_path / "report.json"
    trace = tmp_path / "trace.jsonl"

    def model_factory(settings: object, trace_sink: object) -> ScriptedModel:
        del settings, trace_sink
        return ScriptedModel([json.dumps(model_decision_value())])

    result = evaluation_main(
        [
            "--backend",
            "openrouter",
            "--model",
            "openai/gpt-5.6-sol",
            "--openrouter-provider",
            "OpenAI",
            "--openrouter-api-key-file",
            str(tmp_path / "api-key"),
            "--output-tokens",
            "4096",
            "--reasoning",
            "high",
            "--timeout-seconds",
            "30",
            "--case-directory",
            str(tmp_path),
            "--trace-output",
            str(trace),
            "--output",
            str(output),
        ],
        model_factory=model_factory,
    )

    report = json.loads(output.read_bytes())
    assert result == 0
    assert report["schema_version"] == "lidarr-repair-review-report/v1"
    assert report["settings"]["backend"] == "openrouter"
    assert report["results"][0]["decision"]["action"] == "import_missing_tracks_v1"
    assert trace.stat().st_mode & 0o777 == 0o600
