import io
from pathlib import Path

from nixpkgs_cache_warmer.build import NixBuilder
from nixpkgs_cache_warmer.commands import CommandResult
from nixpkgs_cache_warmer.models import PackageTarget


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result
        self.arguments: tuple[str, ...] | None = None

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        self.arguments = tuple(arguments)
        return self.result


def target(name: str, outputs: tuple[str, ...]) -> PackageTarget:
    return PackageTarget(
        drvPath=Path(f"/nix/store/{name}.drv"),
        name=f"{name}-1",
        pname=name,
        outputs=tuple(Path(output) for output in outputs),
    )


def test_build_maps_printed_outputs_to_successful_targets() -> None:
    one = target("one", ("/nix/store/one",))
    two = target("two", ("/nix/store/two", "/nix/store/two-dev"))
    runner = FakeRunner(CommandResult(1, "/nix/store/one\n", "two failed\n"))
    log = io.StringIO()

    outcome = NixBuilder(runner, Path("/nix")).build((one, two), log)

    assert outcome.successful == (one,)
    assert outcome.failed == (two,)
    assert outcome.outputs == (Path("/nix/store/one"),)
    assert log.getvalue() == "two failed\n"
    assert runner.arguments is not None
    assert "--keep-going" in runner.arguments
    assert "/nix/store/one.drv^*" in runner.arguments
    assert "/nix/store/two.drv^*" in runner.arguments


def test_build_requires_every_output_for_multi_output_target() -> None:
    package = target("multi", ("/nix/store/multi", "/nix/store/multi-dev"))
    outcome = NixBuilder(
        FakeRunner(CommandResult(0, "/nix/store/multi\n", "warning")), Path("/nix")
    ).build((package,), io.StringIO())

    assert outcome.successful == ()
    assert outcome.failed == (package,)
