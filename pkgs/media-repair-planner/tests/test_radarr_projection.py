from __future__ import annotations

import json
import os
from pathlib import Path

from media_repair_planner.contracts import (
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)
from media_repair_planner.decision_validation_core import DecisionViolation, ViolationCode
from media_repair_planner.model_projection import MODEL_CASE_ID
from media_repair_planner.radarr_projection import project_case

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v3/examples"


def test_projects_case_local_identifiers_and_omits_runtime_guards() -> None:
    repair_case = decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())

    projection = project_case(repair_case)
    value = json.loads(projection.case_content)

    assert value["case_id"] == MODEL_CASE_ID
    assert [item["file_id"] for item in value["files"]] == ["file:1", "file:2"]
    assert value["capabilities"][0]["capability_id"] == "capability:1"
    assert value["radarr"]["failure"]["status_messages"][0]["evidence_id"] == "evidence:1"
    assert "download_ref" not in value["download"]
    assert "download_ref" not in value["radarr"]["failure"]
    assert "queue_id" not in value["radarr"]["failure"]
    assert all("fingerprint" not in item for item in value["files"])


def test_restores_canonical_identifiers_in_model_decision() -> None:
    repair_case = decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())
    projection = project_case(repair_case)
    value = json.loads((FIXTURES / "repair-decision-join.json").read_bytes())
    value["case_id"] = MODEL_CASE_ID
    value["capability_id"] = "capability:1"
    value["ordered_file_ids"] = ["file:1", "file:2"]
    value["evidence_refs"] = ["file:1", "file:2", "evidence:3", "evidence:4"]

    restored = projection.restore_decision(decode_decision(json.dumps(value).encode()))
    restored_value = json.loads(encode_decision(restored))

    assert restored_value == json.loads((FIXTURES / "repair-decision-join.json").read_bytes())


def test_projects_authored_dvd_playback_links() -> None:
    value = json.loads((FIXTURES / "repair-case-joinable.json").read_bytes())
    file_id = value["files"][0]["file_id"]
    title = {
        "action": "remux_dvd_v2",
        "navigation_file_id": file_id,
        "source_file_ids": [file_id],
        "title_set": 1,
        "angle_count": 1,
        "duration_ms": 1117200,
        "chapter_count": 1,
        "tracks": [{"kind": "video", "codec": "mpeg2video", "language": None}],
    }
    value["capabilities"] = [
        {
            **title,
            "capability_id": "capability:first",
            "title_number": 1,
            "title_in_set": 1,
            "continues_to": "capability:second",
            "overlaps": [
                {
                    "capability_id": "capability:second",
                    "shared_duration_ms": 1100000,
                    "ranges": [{"start_ms": 17200, "other_start_ms": 0, "duration_ms": 1100000}],
                }
            ],
        },
        {
            **title,
            "capability_id": "capability:second",
            "title_number": 2,
            "title_in_set": 2,
            "equivalent_title_numbers": [3],
        },
    ]

    projection = project_case(decode_case(json.dumps(value).encode()))
    first, second = json.loads(projection.case_content)["capabilities"]

    assert first["continues_to"] == second["capability_id"] == "capability:2"
    assert second["equivalent_title_numbers"] == [3]
    assert first["overlaps"] == [
        {
            "capability_id": second["capability_id"],
            "shared_duration_ms": 1100000,
            "ranges": [{"start_ms": 17200, "other_start_ms": 0, "duration_ms": 1100000}],
        }
    ]


def test_timestamp_units_do_not_change_model_evidence() -> None:
    value = json.loads((FIXTURES / "repair-case-joinable.json").read_bytes())
    original = decode_case(json.dumps(value).encode())
    value["files"][1]["probe"]["streams"][0]["time_base"] = {
        "numerator": 1,
        "denominator": 12800,
    }
    mixed_units = decode_case(json.dumps(value).encode())
    canonical_before = encode_case(mixed_units)

    projection = project_case(mixed_units)

    assert projection.case_content == project_case(original).case_content
    assert encode_case(mixed_units) == canonical_before
    projected_stream = json.loads(projection.case_content)["files"][1]["probe"]["streams"][0]
    assert projected_stream["frame_rate"] == value["files"][1]["probe"]["streams"][0]["frame_rate"]
    assert (
        projected_stream["duration_ms"] == value["files"][1]["probe"]["streams"][0]["duration_ms"]
    )


def test_projects_identifiers_in_retry_correction() -> None:
    repair_case = decode_case((FIXTURES / "repair-case-joinable.json").read_bytes())
    projection = project_case(repair_case)

    correction = projection.project_correction(
        (
            DecisionViolation(
                code=ViolationCode.UNKNOWN_CAPABILITY,
                path=("capability_id",),
                rejected_values=("capability_join_01",),
                allowed_values=("capability_join_01",),
            ),
        )
    )

    assert correction == (
        DecisionViolation(
            code=ViolationCode.UNKNOWN_CAPABILITY,
            path=("capability_id",),
            rejected_values=("capability:1",),
            allowed_values=("capability:1",),
        ),
    )
