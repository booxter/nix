from __future__ import annotations

import json
import os
from pathlib import Path

from media_repair_planner.contracts import decode_case, decode_decision, encode_decision
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
