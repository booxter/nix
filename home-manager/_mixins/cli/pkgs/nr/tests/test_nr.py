import shlex
from collections.abc import Sequence

from nr.cli import main


class RecordingReviewExecutor:
    def __init__(self, status: int = 0) -> None:
        self.status = status
        self.arguments: tuple[str, ...] | None = None

    def run(self, arguments: Sequence[str]) -> int:
        self.arguments = tuple(arguments)
        return self.status


def invoke(
    arguments: Sequence[str],
    *,
    builders: str = "",
    status: int = 0,
) -> tuple[int, tuple[str, ...]]:
    executor = RecordingReviewExecutor(status)
    result = main(
        arguments,
        environment={"NR_BUILDERS": builders},
        executor=executor,
    )
    assert executor.arguments is not None
    return result, executor.arguments


def test_defaults_to_portable_systems_without_an_arm_linux_builder() -> None:
    status, arguments = invoke(
        ["123"],
        builders="ssh-ng://builder x86_64-linux - 4 100 - - -",
    )

    assert status == 0
    assert "--systems=x86_64-linux aarch64-darwin" in arguments


def test_includes_arm_linux_when_a_builder_supports_it() -> None:
    _, arguments = invoke(
        ["123"],
        builders="ssh://builder x86_64-linux,aarch64-linux - 4 100 - - -",
    )

    assert "--systems=x86_64-linux aarch64-linux aarch64-darwin" in arguments


def test_explicit_systems_override_builder_detection() -> None:
    _, arguments = invoke(
        ["-s", "x86_64-linux", "123"],
        builders="ssh://builder aarch64-linux - 4 100 - - -",
    )

    assert "--systems=x86_64-linux" in arguments


def test_maps_review_options_and_builders_to_the_supported_cli() -> None:
    builders = (
        "ssh-ng://first x86_64-linux - 4 100 - - - ; ssh-ng://second aarch64-linux - 4 100 - - -"
    )

    status, arguments = invoke(
        ["-p", "-a", "-t", "-C", "-i", "122", "-i", "121", "123", "124"],
        builders=builders,
        status=7,
    )

    assert status == 7
    assert arguments[:5] == ("nixpkgs-review", "pr", "123", "124", "--no-shell")
    assert arguments[5:9] == ("--include-pr", "122", "--include-pr", "121")
    assert "--extra-nixpkgs-config={ cudaSupport = true; }" in arguments
    assert "--post-result" in arguments
    assert "--approve-pr" in arguments
    assert "--tests" in arguments
    build_argument = next(
        argument for argument in arguments if argument.startswith("--build-args=")
    )
    assert shlex.split(build_argument.removeprefix("--build-args=")) == ["--builders", builders]


def test_omits_build_arguments_without_configured_builders() -> None:
    _, arguments = invoke(["123"])

    assert all(not argument.startswith("--build-args=") for argument in arguments)
