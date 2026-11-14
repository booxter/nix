import json
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from ci_build.cli import NativeCommands, main

OUTPUT = "/nix/store/" + "a" * 32 + "-result"
DEV = "/nix/store/" + "b" * 32 + "-dev"
UNRELATED = "/nix/store/" + "c" * 32 + "-manual-build"


@dataclass
class FakeCommands:
    result: str = field(default_factory=lambda: json.dumps([{"outputs": {"out": OUTPUT}}]))
    build_error: Exception | None = None
    upload_error: Exception | None = None
    uploads: list[str] = field(default_factory=list)
    builds: int = 0

    def capture(self, arguments: Sequence[str]) -> str:
        self.builds += 1
        if self.build_error:
            raise self.build_error
        return self.result

    def run(self, arguments: Sequence[str]) -> None:
        if self.upload_error:
            raise self.upload_error
        self.uploads.extend(
            argument for argument in arguments if argument.startswith("/nix/store/")
        )


@pytest.fixture
def config(tmp_path: Path) -> str:
    path = tmp_path / "attic.toml"
    path.write_text("")
    return str(path)


def test_publishes_all_requested_outputs_including_existing_results(config: str) -> None:
    commands = FakeCommands(
        result=json.dumps([{"outputs": {"out": OUTPUT, "dev": DEV}}, {"outputs": {"out": OUTPUT}}])
    )
    assert main([".#first", ".#second"], config_file=config, commands=commands) == 0
    assert commands.uploads == [OUTPUT, DEV]
    assert UNRELATED not in commands.uploads


@pytest.mark.parametrize(
    "error", [subprocess.CalledProcessError(17, "nix"), OSError("missing nix")]
)
def test_build_failure_does_not_publish(config: str, error: Exception) -> None:
    commands = FakeCommands(build_error=error)
    assert main([".#target"], config_file=config, commands=commands) != 0
    assert commands.uploads == []


@pytest.mark.parametrize("status", [1, -15])
def test_upload_failure_fails_the_job(config: str, status: int) -> None:
    commands = FakeCommands(upload_error=subprocess.CalledProcessError(status, "attic"))
    assert main([".#target"], config_file=config, commands=commands) == 1


@pytest.mark.parametrize(
    "result",
    ["not json", "[]", '[{"outputs": {}}]', '[{"outputs": {"out": "/etc/shadow"}}]'],
)
def test_invalid_results_are_never_uploaded(config: str, result: str) -> None:
    commands = FakeCommands(result=result)
    assert main([".#target"], config_file=config, commands=commands) == 1
    assert commands.uploads == []


def test_missing_credential_prevents_building(tmp_path: Path) -> None:
    commands = FakeCommands()
    assert main([".#target"], config_file=str(tmp_path / "missing"), commands=commands) == 1
    assert commands.builds == 0


def test_native_commands_capture_output_and_report_failures() -> None:
    commands = NativeCommands()
    assert commands.capture(["printf", "result"]) == "result"
    commands.run(["true"])
    with pytest.raises(subprocess.CalledProcessError):
        commands.run(["false"])
