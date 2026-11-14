import io
from pathlib import Path

import pytest
from storage_observability.cli import maintenance_main
from storage_observability.maintenance import guard_raid


@pytest.mark.parametrize("position", ["0", "123456"])
@pytest.mark.parametrize("action", ["reshape", "idle", "frozen"])
def test_unfinished_reshape_blocks_maintenance(tmp_path: Path, position: str, action: str) -> None:
    md = tmp_path / "md127" / "md"
    md.mkdir(parents=True)
    (md / "array_state").write_text("readonly")
    (md / "reshape_position").write_text(position)
    (md / "sync_action").write_text(action)
    stderr = io.StringIO()

    assert guard_raid(tmp_path, stderr) == 1
    assert "md127 has an unfinished reshape" in stderr.getvalue()


def test_completed_reshape_and_non_md_devices_allow_maintenance(tmp_path: Path) -> None:
    (tmp_path / "sda").mkdir()
    md = tmp_path / "md0" / "md"
    md.mkdir(parents=True)
    (md / "array_state").write_text("clean")
    (md / "reshape_position").write_text("none")

    assert guard_raid(tmp_path, io.StringIO()) == 0


def test_inactive_array_blocks_maintenance_before_metadata_is_loaded(tmp_path: Path) -> None:
    md = tmp_path / "md0" / "md"
    md.mkdir(parents=True)
    (md / "array_state").write_text("inactive")

    assert guard_raid(tmp_path, io.StringIO()) == 1


@pytest.mark.parametrize("position", [None, "", "-1", "unexpected"])
def test_unreadable_or_invalid_state_is_not_safe(tmp_path: Path, position: str | None) -> None:
    md = tmp_path / "md0" / "md"
    md.mkdir(parents=True)
    (md / "array_state").write_text("clean")
    if position is not None:
        (md / "reshape_position").write_text(position)

    assert maintenance_main(["--sys-block", str(tmp_path)]) == 1


def test_empty_system_allows_maintenance(tmp_path: Path) -> None:
    assert maintenance_main(["--sys-block", str(tmp_path)]) == 0
