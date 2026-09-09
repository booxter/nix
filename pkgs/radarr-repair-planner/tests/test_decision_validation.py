from __future__ import annotations

import os
from pathlib import Path

from radarr_repair_planner.case_models import RepairCaseV1
from radarr_repair_planner.contracts import decode_case, decode_decision
from radarr_repair_planner.decision_models import RepairDecisionV1
from radarr_repair_planner.decision_validation import (
    DecisionViolation,
    ViolationCode,
    describe_violations,
    validate_decision_for_case,
)

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"]) / "contracts/v1/examples"


def repair_case(name: str = "repair-case-joinable.json") -> RepairCaseV1:
    return decode_case((FIXTURES / name).read_bytes())


def repair_decision(name: str = "repair-decision-join.json") -> RepairDecisionV1:
    return decode_decision((FIXTURES / name).read_bytes())


def test_matching_decision_has_no_violations() -> None:
    assert validate_decision_for_case(repair_case(), repair_decision()) == ()
    assert (
        validate_decision_for_case(
            repair_case("repair-case-manual-importable.json"),
            repair_decision("repair-decision-manual-import.json"),
        )
        == ()
    )


def test_reports_all_case_bound_violations_in_stable_order() -> None:
    case = repair_case()
    decision = repair_decision()
    decision.root.case_id.root = "sha256:" + "0" * 64
    decision.root.evidence_refs.root[0].root = "download_01"
    decision.root.capability_id.root = "capability_missing"
    decision.root.ordered_file_ids[0].root = "file_missing"

    assert validate_decision_for_case(case, decision) == (
        DecisionViolation(
            code=ViolationCode.CASE_ID_MISMATCH,
            path=("case_id",),
            rejected_values=("sha256:" + "0" * 64,),
            allowed_values=(case.case_id.root,),
        ),
        DecisionViolation(
            code=ViolationCode.UNKNOWN_EVIDENCE,
            path=("evidence_refs",),
            rejected_values=("download_01",),
            allowed_values=(
                "capability_join_01",
                "evidence_history_01",
                "evidence_import_01",
                "evidence_import_02",
                "evidence_queue_01",
                "file_01",
                "file_02",
            ),
        ),
        DecisionViolation(
            code=ViolationCode.UNKNOWN_CAPABILITY,
            path=("capability_id",),
            rejected_values=("capability_missing",),
            allowed_values=("capability_join_01",),
        ),
    )


def test_rejects_file_outside_join_capability() -> None:
    case = repair_case()
    decision = repair_decision()
    decision.root.ordered_file_ids[1].root = "file_missing"

    assert validate_decision_for_case(case, decision) == (
        DecisionViolation(
            code=ViolationCode.FILE_OUTSIDE_CAPABILITY,
            path=("ordered_file_ids",),
            rejected_values=("file_missing",),
            allowed_values=("file_01", "file_02"),
        ),
    )


def test_rejects_wrong_manual_import_file() -> None:
    case = repair_case("repair-case-manual-importable.json")
    decision = repair_decision("repair-decision-manual-import.json")
    decision.root.file_id.root = "file_missing"

    assert validate_decision_for_case(case, decision) == (
        DecisionViolation(
            code=ViolationCode.MANUAL_IMPORT_FILE_MISMATCH,
            path=("file_id",),
            rejected_values=("file_missing",),
            allowed_values=("file_manual_01",),
        ),
    )


def test_rejects_action_not_offered_by_capability() -> None:
    case = repair_case("repair-case-manual-importable.json")
    decision = repair_decision()
    decision.root.case_id.root = case.case_id.root
    decision.root.capability_id.root = "capability_manual_import_01"
    decision.root.evidence_refs.root = []

    assert validate_decision_for_case(case, decision) == (
        DecisionViolation(
            code=ViolationCode.ACTION_CAPABILITY_MISMATCH,
            path=("action",),
            rejected_values=("join_parts_v1",),
            allowed_values=("manual_import_file_v1",),
        ),
    )


def test_describes_multiple_violations() -> None:
    violations = (
        DecisionViolation(ViolationCode.CASE_ID_MISMATCH, ("case_id",)),
        DecisionViolation(ViolationCode.UNKNOWN_EVIDENCE, ("evidence_refs",)),
        DecisionViolation(ViolationCode.UNKNOWN_CAPABILITY, ("capability_id",)),
        DecisionViolation(ViolationCode.ACTION_CAPABILITY_MISMATCH, ("action",)),
        DecisionViolation(ViolationCode.FILE_OUTSIDE_CAPABILITY, ("ordered_file_ids",)),
        DecisionViolation(ViolationCode.MANUAL_IMPORT_FILE_MISMATCH, ("file_id",)),
    )

    assert describe_violations(violations) == (
        "decision case_id does not match the case; "
        "decision references evidence absent from the case; "
        "decision references a capability absent from the case; "
        "decision action does not match its capability; "
        "join selects files outside its capability; "
        "manual import file does not match its capability"
    )
