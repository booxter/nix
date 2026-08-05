from pathlib import Path

import pytest

from sops_tools.errors import ToolError
from sops_tools.flake import archive_flake_source

from .fakes import RecordingRunner


def test_archive_flake_source_returns_validated_store_path() -> None:
    runner = RecordingRunner(outputs=['{"path":"/nix/store/source"}'])

    assert archive_flake_source(runner, Path("/repo")) == Path("/nix/store/source")
    assert runner.calls[0][0] == [
        "nix",
        "flake",
        "archive",
        "--json",
        "path:/repo",
    ]


@pytest.mark.parametrize("output", ["garbage", "{}", '{"path":"/tmp/source"}'])
def test_archive_flake_source_rejects_invalid_output(output: str) -> None:
    with pytest.raises(ToolError, match="failed to archive flake source"):
        archive_flake_source(RecordingRunner(outputs=[output]), Path("/repo"))
