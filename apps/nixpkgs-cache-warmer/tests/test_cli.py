import io
from pathlib import Path

from nixpkgs_cache_warmer.cli import run
from nixpkgs_cache_warmer.commands import CommandResult


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        return self.result


class SequencedRunner:
    def __init__(self, results: list[CommandResult]) -> None:
        self.results = results

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        return self.results.pop(0)


ENVIRONMENT = {
    "NIXPKGS_CACHE_WARMER_NIX": "/nix",
    "NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE": "/nix-instantiate",
    "NIXPKGS_CACHE_WARMER_INVENTORY_EXPR": "/inventory.nix",
}


def test_resolve_prints_revision() -> None:
    stdout = io.StringIO()
    status = run(
        ["resolve", "github:NixOS/nixpkgs/staging"],
        ENVIRONMENT,
        FakeRunner(
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            )
        ),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "012345\t/nix/store/source\n"


def test_resolve_prints_json() -> None:
    stdout = io.StringIO()
    status = run(
        ["resolve", "github:NixOS/nixpkgs/staging", "--json"],
        ENVIRONMENT,
        FakeRunner(
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            )
        ),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert '"revision": "012345"' in stdout.getvalue()


def test_warm_reports_success() -> None:
    runner = SequencedRunner(
        [
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            ),
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
                '"outputs":["/nix/store/one"]}]',
                "",
            ),
            CommandResult(0, "/nix/store/a.drv\n", ""),
            CommandResult(0, "/nix/store/one\n", ""),
        ]
    )
    stderr = io.StringIO()
    status = run(
        [
            "warm",
            "github:NixOS/nixpkgs/staging",
            "--maintainer",
            "booxter",
            "--system",
            "x86_64-linux",
        ],
        ENVIRONMENT,
        runner,
        io.StringIO(),
        stderr,
    )

    assert status == 0
    assert "Built 1/1" in stderr.getvalue()


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
