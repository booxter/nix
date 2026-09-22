from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from radarr_repair_planner.cli import main
from radarr_repair_planner.contracts import (
    ContractError,
    decode_case,
    decode_decision,
    encode_case,
    encode_decision,
)

FIXTURES = Path(os.environ["RADARR_REPAIR_CONTRACT_FIXTURES"])
VALID_CASES = sorted((FIXTURES / "contracts/v3/examples").glob("repair-case-*.json"))
VALID_DECISIONS = sorted((FIXTURES / "contracts/v3/examples").glob("repair-decision-*.json"))
INVALID_CASES = sorted((FIXTURES / "contract-tests/v1").glob("request-*.json"))
INVALID_DECISIONS = sorted((FIXTURES / "contract-tests/v1").glob("decision-*.json"))


def test_shared_fixture_sets_are_present() -> None:
    assert VALID_CASES
    assert VALID_DECISIONS
    assert INVALID_CASES
    assert INVALID_DECISIONS


@pytest.mark.parametrize("path", VALID_CASES, ids=lambda path: path.name)
def test_valid_case_examples_materialize(path: Path) -> None:
    repair_case = decode_case(path.read_bytes())

    assert repair_case.schema_version == "radarr-repair/v3"
    assert repair_case.case_id.root.startswith("sha256:")
    assert decode_case(encode_case(repair_case)) == repair_case


@pytest.mark.parametrize("path", VALID_DECISIONS, ids=lambda path: path.name)
def test_valid_decision_examples_round_trip(path: Path) -> None:
    decision = decode_decision(path.read_bytes())

    encoded = encode_decision(decision)
    decoded = decode_decision(encoded)
    assert decoded == decision
    assert json.loads(encoded)["schema_version"] == "radarr-repair/v3"


@pytest.mark.parametrize("path", INVALID_CASES, ids=lambda path: path.name)
def test_invalid_case_examples_are_rejected(path: Path) -> None:
    with pytest.raises(ContractError, match="contract validation failed"):
        decode_case(path.read_bytes())


@pytest.mark.parametrize("path", INVALID_DECISIONS, ids=lambda path: path.name)
def test_invalid_decision_examples_are_rejected(path: Path) -> None:
    with pytest.raises(ContractError, match="contract validation failed"):
        decode_decision(path.read_bytes())


def test_invalid_json_is_rejected() -> None:
    with pytest.raises(ContractError, match="invalid JSON"):
        decode_case(b"not JSON")
    with pytest.raises(ContractError, match="invalid JSON constant NaN"):
        decode_case(b"NaN")


def test_invalid_decision_cannot_be_encoded() -> None:
    decision = decode_decision(VALID_DECISIONS[0].read_bytes())
    decision.root.case_id.root = "invalid"

    with pytest.raises(ContractError, match="contract validation failed"):
        encode_decision(decision)


def test_cli_validates_files(capsys: pytest.CaptureFixture[str]) -> None:
    valid = VALID_CASES[0]
    invalid = INVALID_DECISIONS[0]

    assert main(["validate-case", str(valid)]) == 0
    assert main(["validate-decision", str(invalid)]) == 1
    assert "contract validation failed" in capsys.readouterr().err


def test_cli_reports_unreadable_input(capsys: pytest.CaptureFixture[str], tmp_path: Path) -> None:
    missing = tmp_path / "missing.json"

    assert main(["validate-case", str(missing)]) == 1
    assert "missing.json" in capsys.readouterr().err
