from __future__ import annotations

import json
from typing import Any

import httpx
from radarr_repair_planner.api import ContractEndpoint, create_app
from radarr_repair_planner.case_models import RepairCaseV2
from radarr_repair_planner.decision_models import RepairDecisionV2
from radarr_repair_planner.decision_validation import DecisionViolation, ViolationCode
from radarr_repair_planner.lidarr_case_models import LidarrRepairCaseV1
from radarr_repair_planner.lidarr_contracts import (
    ContractError,
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)
from radarr_repair_planner.lidarr_decision_models import LidarrRepairDecisionV1
from radarr_repair_planner.lidarr_planning import LidarrPlanner
from radarr_repair_planner.lidarr_validation import (
    validate_decision_for_case,
    validate_decision_object,
)

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
                "number": str(number),
                "absolute_number": number,
                "medium_number": 1,
                "title": title,
                "duration_ms": 180000 + number,
                "has_file": False,
            }
        )
    return {
        "schema_version": "lidarr-repair/v1",
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
                "title": "Album",
                "disambiguation": "",
                "format": "Album",
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
                "action": "import_track_set_v1",
                "capability_id": "capability:one",
                "album_id": 3,
                "artifact_ids": ["artifact:1", "artifact:2"],
                "release_ids": [4],
                "track_ids": [5, 6],
            }
        ],
    }


def decision_value(**changes: object) -> dict[str, object]:
    value: dict[str, object] = {
        "schema_version": "lidarr-repair/v1",
        "case_id": CASE_ID,
        "action": "import_track_set_v1",
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


def repair_case() -> LidarrRepairCaseV1:
    return decode_case(json.dumps(case_value()).encode())


def repair_decision(**changes: object) -> LidarrRepairDecisionV1:
    return decode_decision(json.dumps(decision_value(**changes)).encode())


class ScriptedModel:
    def __init__(self, outputs: list[str | Exception]) -> None:
        self.outputs = outputs
        self.calls: list[tuple[str, str, dict[str, Any], str, tuple[DecisionViolation, ...]]] = []

    async def decide_json(
        self,
        system_instruction: str,
        case_content: str,
        decision_schema: dict[str, Any],
        case_id: str,
        correction: tuple[DecisionViolation, ...] = (),
    ) -> str:
        self.calls.append((system_instruction, case_content, decision_schema, case_id, correction))
        output = self.outputs.pop(0)
        if isinstance(output, Exception):
            raise output
        return output


async def test_lidarr_planner_returns_complete_mapping() -> None:
    expected = repair_decision()
    model = ScriptedModel([encode_decision(expected).decode()])

    outcome = await LidarrPlanner(model).plan_with_outcome(repair_case())

    assert outcome.decision == expected
    assert outcome.attempts == 1
    assert not outcome.used_fallback
    assert model.calls[0][3] == CASE_ID
    assert json.loads(model.calls[0][1]) == case_value()


async def test_lidarr_planner_corrects_invalid_mapping_then_falls_back() -> None:
    invalid = json.dumps(
        decision_value(
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


async def test_lidarr_planner_corrects_malformed_output() -> None:
    model = ScriptedModel(["not JSON", json.dumps(decision_value())])

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


def test_lidarr_no_repair_is_valid() -> None:
    decision = decode_decision(
        json.dumps(
            {
                "schema_version": "lidarr-repair/v1",
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
    assert unknown[0].allowed_values == ("no_repair", "import_track_set_v1")


class NeverRadarrPlanner:
    async def plan(self, repair_case: RepairCaseV2) -> RepairDecisionV2:
        del repair_case
        raise AssertionError("wrong endpoint")


class StaticLidarrPlanner:
    async def plan(self, repair_case: LidarrRepairCaseV1) -> LidarrRepairDecisionV1:
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
        additional_endpoints={"/lidarr/v1/repair-plans": endpoint},
    )
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://planner") as client:
        response = await client.post(
            "/lidarr/v1/repair-plans",
            content=encode_case(repair_case()),
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 200
    assert decode_decision(response.content) == repair_decision()
