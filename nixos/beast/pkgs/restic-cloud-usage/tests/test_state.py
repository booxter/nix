from pathlib import Path

from restic_cloud_usage.cli import _load_state
from restic_cloud_usage.models import ExporterState


def test_missing_or_invalid_state_starts_empty(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    assert _load_state(path) == ExporterState()

    path.write_text("not json")
    assert _load_state(path) == ExporterState()
