from pathlib import Path

import pytest

from nixpkgs_cache_warmer.commands import CommandError, CommandResult
from nixpkgs_cache_warmer.inventory import Inventory


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result
        self.arguments: tuple[str, ...] | None = None

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        self.arguments = tuple(arguments)
        return self.result


def test_inventory_parses_package_targets() -> None:
    runner = FakeRunner(
        CommandResult(
            0,
            '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
            '"outputs":["/nix/store/one"]}]',
            "",
        )
    )

    targets = Inventory(runner, Path("/nix"), Path("/inventory.nix")).targets(
        Path("/source"), "booxter", "x86_64-linux", ("^firefox($|-)",)
    )

    assert len(targets) == 1
    assert targets[0].pname == "one"
    assert targets[0].outputs == (Path("/nix/store/one"),)
    assert runner.arguments is not None
    assert runner.arguments[:5] == (
        "/nix",
        "/inventory.nix",
        "--eval",
        "--strict",
        "--json",
    )
    assert runner.arguments[-2:] == ("excludePnamePatternsJson", '["^firefox($|-)"]')
    assert "/source" in runner.arguments


def test_inventory_reports_evaluation_failure() -> None:
    runner = FakeRunner(CommandResult(1, "", "bad expression\n"))

    with pytest.raises(CommandError, match="Nix evaluation failed: bad expression"):
        Inventory(runner, Path("/nix"), Path("/inventory.nix")).targets(
            Path("/source"), "booxter", "x86_64-linux"
        )


def test_inventory_rejects_invalid_json() -> None:
    runner = FakeRunner(CommandResult(0, "{}", ""))

    with pytest.raises(CommandError, match="invalid package inventory"):
        Inventory(runner, Path("/nix"), Path("/inventory.nix")).targets(
            Path("/source"), "booxter", "x86_64-linux"
        )
