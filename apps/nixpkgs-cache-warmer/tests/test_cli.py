import io
from pathlib import Path

from nixpkgs_cache_warmer.cli import run
from nixpkgs_cache_warmer.commands import CommandResult


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        return self.result


ENVIRONMENT = {
    "NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE": "/nix-instantiate",
    "NIXPKGS_CACHE_WARMER_INVENTORY_EXPR": "/inventory.nix",
}


def test_targets_prints_human_inventory() -> None:
    stdout = io.StringIO()
    status = run(
        ["targets", "--source", "/source", "--maintainer", "booxter", "--system", "x86_64-linux"],
        ENVIRONMENT,
        FakeRunner(
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
                '"outputs":["/nix/store/one"]}]',
                "",
            )
        ),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "one\t/nix/store/a.drv\n"


def test_targets_prints_json_inventory() -> None:
    stdout = io.StringIO()
    status = run(
        [
            "targets",
            "--source",
            "/source",
            "--maintainer",
            "booxter",
            "--system",
            "x86_64-linux",
            "--json",
        ],
        ENVIRONMENT,
        FakeRunner(CommandResult(0, "[]", "")),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "[]\n"


def test_targets_reports_missing_packaged_configuration() -> None:
    stderr = io.StringIO()
    status = run(
        ["targets", "--source", "/source", "--maintainer", "booxter", "--system", "x86_64-linux"],
        {},
        FakeRunner(CommandResult(0, "[]", "")),
        io.StringIO(),
        stderr,
    )

    assert status == 2
    assert "missing packaged setting" in stderr.getvalue()


def test_targets_reports_nix_failure() -> None:
    stderr = io.StringIO()
    status = run(
        [
            "targets",
            "--source",
            str(Path("/source")),
            "--maintainer",
            "booxter",
            "--system",
            "x86_64-linux",
        ],
        ENVIRONMENT,
        FakeRunner(CommandResult(1, "", "failed")),
        io.StringIO(),
        stderr,
    )

    assert status == 1
    assert "Nix evaluation failed" in stderr.getvalue()
