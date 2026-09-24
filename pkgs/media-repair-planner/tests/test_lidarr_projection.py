from __future__ import annotations

import json

import pytest
from media_repair_planner.decision_validation_core import DecisionViolation, ViolationCode
from media_repair_planner.lidarr_contracts import decode_case, decode_decision
from media_repair_planner.lidarr_projection import project_case
from media_repair_planner.model_projection import MODEL_CASE_ID
from test_lidarr_planning import case_value, decision_value


def test_projects_compact_model_evidence() -> None:
    projection = project_case(decode_case(json.dumps(case_value()).encode()))
    value = json.loads(projection.case_content)

    assert value["case_id"] == MODEL_CASE_ID
    assert value["capabilities"] == [{"capability_id": "capability:1", "release_id": 4}]
    assert "queue_id" not in value["queue"]
    assert "download_ref" not in value["queue"]
    assert "fingerprint" not in value["artifacts"][0]
    assert "foreign_release_id" not in value["releases"][0]


def test_restores_canonical_capability_in_decision() -> None:
    projection = project_case(decode_case(json.dumps(case_value()).encode()))
    value = decision_value(case_id=MODEL_CASE_ID, capability_id="capability:1")
    decision = decode_decision(json.dumps(value).encode())

    restored = projection.restore_decision(decision)

    assert restored.root.capability_id.root == "capability:one"
    assert restored.root.case_id.root == case_value()["case_id"]


def test_projects_retry_correction_ids() -> None:
    projection = project_case(decode_case(json.dumps(case_value()).encode()))

    projected = projection.project_correction(
        (
            DecisionViolation(
                code=ViolationCode.UNKNOWN_CAPABILITY,
                path=("capability_id",),
                rejected_values=("capability:missing",),
                allowed_values=("capability:one",),
            ),
        )
    )

    assert projected[0].rejected_values == ("capability:missing",)
    assert projected[0].allowed_values == ("capability:1",)


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("album_id", 9, "offered album"),
        ("artifact_ids", ["artifact:1"], "every artifact"),
        ("track_ids", [5], "missing tracks"),
    ],
)
def test_rejects_capability_that_cannot_be_safely_derived(
    field: str,
    value: object,
    message: str,
) -> None:
    case = case_value()
    capabilities = case["capabilities"]
    assert isinstance(capabilities, list)
    capability = capabilities[0]
    assert isinstance(capability, dict)
    capability[field] = value

    with pytest.raises(ValueError, match=message):
        project_case(decode_case(json.dumps(case).encode()))
