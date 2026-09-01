from __future__ import annotations

import json
import os
from pathlib import Path
from uuid import UUID

import pytest
from pydantic import ValidationError

from arr_post_processor.errors import NeedsAttention
from arr_post_processor.radarr_repair import (
    RepairOutcome,
    RepairResult,
    RepairTask,
    load_repair_result,
    render_repair_instruction,
)


ATTEMPT_ID = UUID("12345678-1234-5678-1234-567812345678")
FINGERPRINT = "a" * 64


def task() -> RepairTask:
    return RepairTask(
        attempt_id=ATTEMPT_ID,
        download_id="download-id",
        source_fingerprint=FINGERPRINT,
        movie_id=42,
        movie_title="Test Movie",
        movie_year=2020,
        movie_runtime_minutes=120,
        queue_title="Test.Movie.2020.1080p",
        source_path="input/torrents/Test.Movie.2020.1080p",
        output_path="output/processed/download-id/12345678",
    )


def result_payload(**changes: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema_version": 1,
        "attempt_id": str(ATTEMPT_ID),
        "download_id": "download-id",
        "source_fingerprint": FINGERPRINT,
        "outcome": "repaired",
        "candidate": "Test Movie (2020).mkv",
        "reason": "joined two compatible parts and verified the result",
    }
    payload.update(changes)
    return payload


def write_result(root: Path, payload: dict[str, object]) -> None:
    (root / "report.md").write_text("# Repair report\n")
    (root / "result.json").write_text(json.dumps(payload))


def test_instruction_contains_the_exact_contract() -> None:
    instruction = render_repair_instruction(task())

    assert "Work autonomously: do not request approval" in instruction
    assert '"attempt_id": "12345678-1234-5678-1234-567812345678"' in instruction
    assert '"source_path": "input/torrents/Test.Movie.2020.1080p"' in instruction
    assert "write result.json last" in instruction


@pytest.mark.parametrize(
    "changes",
    [
        {"outcome": "repaired", "candidate": None},
        {"outcome": "unresolved", "candidate": "movie.mkv"},
        {"candidate": "../movie.mkv"},
        {"candidate": "/movie.mkv"},
        {"candidate": "nested\\movie.mkv"},
        {"unknown": "field"},
    ],
)
def test_result_schema_rejects_ambiguous_or_unsafe_contracts(changes: dict[str, object]) -> None:
    with pytest.raises(ValidationError):
        RepairResult.model_validate(result_payload(**changes))


def test_unresolved_result_has_no_candidate(tmp_path: Path) -> None:
    write_result(tmp_path, result_payload(outcome="unresolved", candidate=None))

    validated = load_repair_result(tmp_path, task())

    assert validated.result.outcome is RepairOutcome.UNRESOLVED
    assert validated.candidate is None


def test_repaired_result_resolves_group_readable_candidate(tmp_path: Path) -> None:
    candidate = tmp_path / "Test Movie (2020).mkv"
    candidate.write_bytes(b"media")
    candidate.chmod(0o660)
    write_result(tmp_path, result_payload())

    validated = load_repair_result(tmp_path, task())

    assert validated.candidate == candidate.resolve()


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"attempt_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}, "requested attempt"),
        ({"download_id": "other"}, "requested attempt"),
        ({"source_fingerprint": "b" * 64}, "requested attempt"),
        ({"candidate": "movie.txt"}, "unsupported suffix"),
    ],
)
def test_result_validation_rejects_mismatch_and_bad_suffix(
    tmp_path: Path, changes: dict[str, object], message: str
) -> None:
    candidate = tmp_path / str(changes.get("candidate", "Test Movie (2020).mkv"))
    candidate.write_bytes(b"media")
    candidate.chmod(0o660)
    write_result(tmp_path, result_payload(**changes))

    with pytest.raises(NeedsAttention, match=message):
        load_repair_result(tmp_path, task())


def test_result_validation_rejects_missing_invalid_and_unreadable_results(tmp_path: Path) -> None:
    with pytest.raises(NeedsAttention, match="missing"):
        load_repair_result(tmp_path, task())

    (tmp_path / "result.json").write_text("not json")
    with pytest.raises(NeedsAttention, match="invalid"):
        load_repair_result(tmp_path, task())

    candidate = tmp_path / "Test Movie (2020).mkv"
    candidate.write_bytes(b"media")
    candidate.chmod(0o600)
    write_result(tmp_path, result_payload())
    with pytest.raises(NeedsAttention, match="group-readable"):
        load_repair_result(tmp_path, task())

    write_result(tmp_path, result_payload(candidate="missing.mkv"))
    with pytest.raises(NeedsAttention, match="candidate is unavailable"):
        load_repair_result(tmp_path, task())


def test_result_validation_requires_report(tmp_path: Path) -> None:
    candidate = tmp_path / "Test Movie (2020).mkv"
    candidate.write_bytes(b"media")
    candidate.chmod(0o660)
    write_result(tmp_path, result_payload())
    (tmp_path / "report.md").unlink()

    with pytest.raises(NeedsAttention, match="report"):
        load_repair_result(tmp_path, task())


def test_result_validation_rejects_symlinks(tmp_path: Path) -> None:
    outside = tmp_path.parent / f"{tmp_path.name}-outside.mkv"
    outside.write_bytes(b"media")
    outside.chmod(0o660)
    candidate = tmp_path / "Test Movie (2020).mkv"
    candidate.symlink_to(outside)
    write_result(tmp_path, result_payload())

    with pytest.raises(NeedsAttention, match="symlink"):
        load_repair_result(tmp_path, task())

    candidate.unlink()
    nested = tmp_path / "nested"
    nested.mkdir()
    nested_candidate = nested / "movie.mkv"
    nested_candidate.write_bytes(b"media")
    nested_candidate.chmod(0o660)
    (tmp_path / "result.json").unlink()
    (tmp_path / "result.json").symlink_to(nested_candidate)
    with pytest.raises(NeedsAttention, match="manifest is a symlink"):
        load_repair_result(tmp_path, task())


def test_task_rejects_paths_outside_the_workspace() -> None:
    values = task().model_dump()
    values["source_path"] = "../source"
    with pytest.raises(ValidationError):
        RepairTask.model_validate(values)


def test_candidate_file_mode_is_not_changed(tmp_path: Path) -> None:
    candidate = tmp_path / "Test Movie (2020).mkv"
    candidate.write_bytes(b"media")
    candidate.chmod(0o640)
    write_result(tmp_path, result_payload())

    load_repair_result(tmp_path, task())

    assert os.stat(candidate).st_mode & 0o777 == 0o640
