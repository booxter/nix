from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID

import pytest
from arr_post_processor.errors import NeedsAttention
from arr_post_processor.lidarr_repair import RepairTask, load_repair_result

ATTEMPT_ID = UUID("11111111-2222-3333-4444-555555555555")
FINGERPRINT = "a" * 64


def task() -> RepairTask:
    return RepairTask.model_validate(
        {
            "attempt_id": str(ATTEMPT_ID),
            "download_id": "download-1",
            "source_fingerprint": FINGERPRINT,
            "queue_title": "Artist - Album",
            "catalog": {
                "album": {
                    "id": 8,
                    "title": "Album",
                    "artistId": 7,
                    "artist": {"id": 7, "artistName": "Artist"},
                    "releases": [
                        {
                            "id": 9,
                            "title": "Album",
                            "mediumCount": 1,
                            "trackCount": 2,
                            "duration": 360000,
                        }
                    ],
                },
                "releases": [
                    {
                        "release": {
                            "id": 9,
                            "title": "Album",
                            "mediumCount": 1,
                            "trackCount": 2,
                            "duration": 360000,
                        },
                        "tracks": [
                            {
                                "id": 10,
                                "title": "One",
                                "mediumNumber": 1,
                                "trackNumber": 1,
                                "absoluteTrackNumber": 1,
                                "duration": 180000,
                            },
                            {
                                "id": 11,
                                "title": "Two",
                                "mediumNumber": 1,
                                "trackNumber": 2,
                                "absoluteTrackNumber": 2,
                                "duration": 180000,
                            },
                        ],
                    }
                ],
            },
            "source_path": "input/torrents/Artist - Album",
            "output_path": "output/processed/download-1/attempt",
        }
    )


def write_result(root: Path, **changes: object) -> None:
    payload: dict[str, object] = {
        "schema_version": 1,
        "attempt_id": str(ATTEMPT_ID),
        "download_id": "download-1",
        "source_fingerprint": FINGERPRINT,
        "outcome": "repaired",
        "release_id": 9,
        "files": [
            {"candidate": "01.flac", "expected_track_ids": [10]},
            {"candidate": "02.flac", "expected_track_ids": [11]},
        ],
        "reason": "complete CUE split",
    }
    payload.update(changes)
    root.mkdir()
    (root / "report.md").write_text("# Report\n")
    for name in ("01.flac", "02.flac"):
        (root / name).write_bytes(b"audio")
        (root / name).chmod(0o640)
    (root / "result.json").write_text(json.dumps(payload))


def test_valid_result_covers_selected_release(tmp_path: Path) -> None:
    root = tmp_path / "attempt"
    write_result(root)

    result = load_repair_result(root, task())

    assert result.result.release_id == 9
    assert [item.expected_track_ids for item in result.files] == [(10,), (11,)]


@pytest.mark.parametrize(
    "changes",
    [
        {"release_id": 99},
        {"files": [{"candidate": "01.flac", "expected_track_ids": [10]}]},
        {
            "files": [
                {"candidate": "01.flac", "expected_track_ids": [10]},
                {"candidate": "01.flac", "expected_track_ids": [11]},
            ]
        },
        {
            "files": [
                {"candidate": "01.flac", "expected_track_ids": [10]},
                {"candidate": "02.flac", "expected_track_ids": [10, 11]},
            ]
        },
    ],
)
def test_result_rejects_wrong_or_ambiguous_coverage(
    tmp_path: Path, changes: dict[str, object]
) -> None:
    root = tmp_path / "attempt"
    write_result(root, **changes)

    with pytest.raises((NeedsAttention, ValueError)):
        load_repair_result(root, task())


def test_unresolved_result_has_no_files(tmp_path: Path) -> None:
    root = tmp_path / "attempt"
    write_result(root, outcome="unresolved", release_id=None, files=[])

    result = load_repair_result(root, task())

    assert not result.files


def test_result_rejects_escape_and_symlink(tmp_path: Path) -> None:
    root = tmp_path / "attempt"
    write_result(
        root,
        files=[
            {"candidate": "linked.flac", "expected_track_ids": [10]},
            {"candidate": "02.flac", "expected_track_ids": [11]},
        ],
    )
    (root / "linked.flac").symlink_to(root / "01.flac")

    with pytest.raises(NeedsAttention, match="symlink"):
        load_repair_result(root, task())


def test_task_rejects_paths_outside_workspace() -> None:
    payload = task().model_dump(mode="json")
    payload["source_path"] = "../source"

    with pytest.raises(ValueError):
        RepairTask.model_validate(payload)
