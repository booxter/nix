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


class SequencedRunner:
    def __init__(self, results: list[CommandResult]) -> None:
        self.results = results

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        return self.results.pop(0)


def test_inventory_parses_package_targets() -> None:
    runner = SequencedRunner(
        [
            CommandResult(0, '[["one"]]', ""),
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
                '"outputs":["/nix/store/one"]}]',
                "",
            ),
        ]
    )

    targets = Inventory(runner, Path("/nix"), Path("/inventory.nix")).targets(
        Path("/source"), "booxter", "x86_64-linux", ("firefox.*",), ("one",)
    )

    assert len(targets) == 1
    assert targets[0].pname == "one"
    assert targets[0].outputs == (Path("/nix/store/one"),)


def test_inventory_discovers_package_selectors() -> None:
    runner = FakeRunner(CommandResult(0, '[["one"],["python313Packages","two"]]', ""))

    selectors = Inventory(runner, Path("/nix"), Path("/inventory.nix")).discover(
        Path("/source"), "booxter", "x86_64-linux"
    )

    assert selectors == (("one",), ("python313Packages", "two"))
    assert runner.arguments is not None
    assert runner.arguments[-2:] == ("output", "selectors")


def test_inventory_reports_evaluation_failure() -> None:
    runner = SequencedRunner(
        [CommandResult(0, '[["one"]]', ""), CommandResult(1, "", "bad expression\n")]
    )

    with pytest.raises(CommandError, match="Nix evaluation failed: bad expression"):
        Inventory(runner, Path("/nix"), Path("/inventory.nix")).targets(
            Path("/source"), "booxter", "x86_64-linux"
        )


def test_inventory_rejects_invalid_json() -> None:
    runner = SequencedRunner([CommandResult(0, '[["one"]]', ""), CommandResult(0, "{}", "")])

    with pytest.raises(CommandError, match="invalid package inventory"):
        Inventory(runner, Path("/nix"), Path("/inventory.nix")).targets(
            Path("/source"), "booxter", "x86_64-linux"
        )


def test_inventory_instantiates_selected_derivations() -> None:
    inventory_json = (
        '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one","outputs":["/nix/store/one"]}]'
    )
    targets = Inventory(
        SequencedRunner(
            [
                CommandResult(0, '[["one"]]', ""),
                CommandResult(0, inventory_json, ""),
                CommandResult(0, "/nix/store/a.drv\n", ""),
            ]
        ),
        Path("/nix-instantiate"),
        Path("/inventory.nix"),
    ).instantiate(Path("/source"), "booxter", "x86_64-linux")

    assert len(targets) == 1
    assert targets[0].drvPath == Path("/nix/store/a.drv")


def test_inventory_rejects_mismatched_instantiation() -> None:
    inventory_json = (
        '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one","outputs":["/nix/store/one"]}]'
    )
    with pytest.raises(CommandError, match="do not match"):
        Inventory(
            SequencedRunner(
                [
                    CommandResult(0, '[["one"]]', ""),
                    CommandResult(0, inventory_json, ""),
                    CommandResult(0, "/nix/store/other.drv\n", ""),
                ]
            ),
            Path("/nix-instantiate"),
            Path("/inventory.nix"),
        ).instantiate(Path("/source"), "booxter", "x86_64-linux")
