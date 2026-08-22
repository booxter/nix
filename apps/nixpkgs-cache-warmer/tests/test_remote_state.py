from pathlib import Path

import pytest

from nixpkgs_cache_warmer.commands import CommandError, CommandResult
from nixpkgs_cache_warmer.state import RemoteStateReader


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result
        self.arguments: tuple[str, ...] | None = None

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        self.arguments = tuple(arguments)
        return self.result


def test_reads_state_from_configured_host() -> None:
    runner = FakeRunner(CommandResult(0, '{"schema_version":1,"targets":[]}', ""))

    state = RemoteStateReader(
        runner,
        Path("/ssh"),
        "mmini",
        Path("/var/lib/nixpkgs-cache-warmer/status.json"),
    ).read()

    assert state.targets == ()
    assert runner.arguments == (
        "/ssh",
        "mmini",
        "/bin/cat /var/lib/nixpkgs-cache-warmer/status.json",
    )


def test_reports_remote_read_failure() -> None:
    with pytest.raises(CommandError, match="failed to read.*mmini.*not found"):
        RemoteStateReader(
            FakeRunner(CommandResult(1, "", "not found")),
            Path("/ssh"),
            "mmini",
            Path("/var/lib/nixpkgs-cache-warmer/status.json"),
        ).read()
