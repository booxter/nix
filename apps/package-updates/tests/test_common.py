from __future__ import annotations

import io
import json
import os
import sys
from pathlib import Path

import pytest

from package_updates.common import (
    CommandResult,
    SubprocessRunner,
    ToolPaths,
    UpdateError,
    atomic_write_json,
    checked,
    find_repo_root,
    print_error,
)


def test_finds_repository_root_from_nested_directory(tmp_path: Path) -> None:
    (tmp_path / ".git").mkdir()
    (tmp_path / "flake.nix").touch()
    nested = tmp_path / "a" / "b"
    nested.mkdir(parents=True)
    assert find_repo_root(nested) == tmp_path
    with pytest.raises(UpdateError, match="not inside"):
        find_repo_root(tmp_path.parent / "unrelated")


def test_atomic_json_write_preserves_mode_and_sorts_keys(tmp_path: Path) -> None:
    output = tmp_path / "pins.json"
    output.write_text("{}\n")
    output.chmod(0o640)
    atomic_write_json(output, {"z": 1, "a": 2})
    assert output.read_text() == '{\n  "a": 2,\n  "z": 1\n}\n'
    assert output.stat().st_mode & 0o777 == 0o640


def test_command_helpers_report_failures_and_stream_success(tmp_path: Path) -> None:
    runner = SubprocessRunner()
    captured = runner.run(
        [sys.executable, "-c", "print('ok')"],
        cwd=tmp_path,
    )
    assert checked(captured, "python") == "ok\n"
    with pytest.raises(UpdateError, match="command failed: nope"):
        checked(CommandResult(2, stderr="nope\n"), "command")
    stderr = io.StringIO()
    assert print_error(ValueError("bad input"), stderr) == 1
    assert stderr.getvalue() == "bad input\n"


def test_tool_paths_accept_explicit_packaged_executables(monkeypatch: pytest.MonkeyPatch) -> None:
    values = {
        "PACKAGE_UPDATES_NIX": "/nix",
        "PACKAGE_UPDATES_NIX_UPDATE": "/nix-update",
        "PACKAGE_UPDATES_NIX_PREFETCH_DOCKER": "/prefetch",
        "PACKAGE_UPDATES_SKOPEO": "/skopeo",
        "PACKAGE_UPDATES_SELECT_NODEJS": "/select-nodejs",
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    tools = ToolPaths.from_environment()
    assert tools.nix == "/nix"
    assert tools.select_nodejs == "/select-nodejs"


def test_atomic_write_creates_parent_and_valid_json(tmp_path: Path) -> None:
    output = tmp_path / "nested" / "pins.json"
    atomic_write_json(output, {"value": True})
    assert json.loads(output.read_text()) == {"value": True}
    assert os.access(output, os.R_OK)
