from pathlib import Path

import pytest

from nixpkgs_cache_warmer.commands import CommandError, CommandResult
from nixpkgs_cache_warmer.resolver import SourceResolver


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result
        self.arguments: tuple[str, ...] | None = None

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        self.arguments = tuple(arguments)
        return self.result


def test_resolves_flake_to_revision_and_store_source() -> None:
    runner = FakeRunner(
        CommandResult(
            0,
            '{"locked":{"rev":"0123456789abcdef"},"path":"/nix/store/source"}',
            "",
        )
    )

    resolved = SourceResolver(runner, Path("/nix")).resolve("github:NixOS/nixpkgs/staging")

    assert resolved.revision == "0123456789abcdef"
    assert resolved.source == Path("/nix/store/source")
    assert runner.arguments == (
        "/nix",
        "flake",
        "metadata",
        "--refresh",
        "--json",
        "github:NixOS/nixpkgs/staging",
    )


def test_reports_resolution_failure() -> None:
    with pytest.raises(CommandError, match="failed to resolve.*network unavailable"):
        SourceResolver(
            FakeRunner(CommandResult(1, "", "network unavailable")), Path("/nix")
        ).resolve("github:NixOS/nixpkgs/staging")


@pytest.mark.parametrize(
    ("metadata", "message"),
    [
        ("{}", "invalid metadata"),
        ('{"locked":{},"path":"/nix/store/source"}', "did not resolve to a Git revision"),
    ],
)
def test_rejects_metadata_without_a_revision(metadata: str, message: str) -> None:
    with pytest.raises(CommandError, match=message):
        SourceResolver(FakeRunner(CommandResult(0, metadata, "")), Path("/nix")).resolve(
            "path:/source"
        )
