import io
from pathlib import Path

import pytest

from nixpkgs_cache_warmer.commands import CommandError, CommandResult
from nixpkgs_cache_warmer.publish import AtticPublisher


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result
        self.arguments: tuple[str, ...] | None = None

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        self.arguments = tuple(arguments)
        return self.result


def test_publishes_outputs_without_overriding_upstream_filter() -> None:
    runner = FakeRunner(CommandResult(0, "uploaded\n", ""))
    log = io.StringIO()

    AtticPublisher(runner, Path("/attic")).publish(
        "home:default", (Path("/nix/store/one"), Path("/nix/store/two")), log
    )

    assert runner.arguments is not None
    assert runner.arguments[:3] == ("/attic", "push", "home:default")
    assert "--ignore-upstream-cache-filter" not in runner.arguments
    assert "Published outputs" in log.getvalue()


def test_reports_attic_failure() -> None:
    with pytest.raises(CommandError, match="Attic push.*denied"):
        AtticPublisher(FakeRunner(CommandResult(1, "", "denied")), Path("/attic")).publish(
            "home:default", (Path("/nix/store/one"),), io.StringIO()
        )


def test_skips_empty_output_set() -> None:
    runner = FakeRunner(CommandResult(0, "", ""))
    AtticPublisher(runner, Path("/attic")).publish("home:default", (), io.StringIO())
    assert runner.arguments is None
