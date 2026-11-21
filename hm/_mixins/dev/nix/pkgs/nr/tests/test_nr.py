import subprocess
from collections.abc import Sequence
from pathlib import Path

import pytest
from nr.cli import main
from nr.review import ReviewOptions, ReviewRequest, prepare_mac_linux_builder

MAC_BUILDERS = "ssh-ng://builder@linux-builder aarch64-linux,x86_64-linux - 4"


class RecordingGcRunner:
    def __init__(self, status: int = 0) -> None:
        self.status = status
        self.runs = 0

    def run(
        self, arguments: Sequence[str], *, cwd: Path | None = None, input: str = ""
    ) -> subprocess.CompletedProcess[str]:
        self.runs += 1
        return subprocess.CompletedProcess(arguments, self.status, "", "authentication failed")


class RecordingReviewExecutor:
    def __init__(self, status: int = 0) -> None:
        self.status = status
        self.options: ReviewOptions | None = None

    def run(self, options: ReviewOptions) -> int:
        self.options = options
        return self.status


def invoke(
    arguments: Sequence[str],
    *,
    builders: str = "",
    local_builders: str = "",
    status: int = 0,
) -> tuple[int, ReviewOptions]:
    executor = RecordingReviewExecutor(status)
    result = main(
        arguments,
        environment={"NR_BUILDERS": builders, "NR_LOCAL_BUILDERS": local_builders},
        executor=executor,
    )
    assert executor.options is not None
    return result, executor.options


def test_defaults_to_portable_systems_without_an_arm_linux_builder() -> None:
    status, options = invoke(["123"], builders="ssh-ng://builder x86_64-linux - 4 100 - - -")

    assert status == 0
    assert options.systems == "x86_64-linux aarch64-darwin"


def test_includes_arm_linux_when_a_builder_supports_it() -> None:
    _, options = invoke(["123"], builders="ssh://builder x86_64-linux,aarch64-linux - 4 100 - - -")

    assert options.systems == "x86_64-linux aarch64-linux aarch64-darwin"


def test_explicit_systems_override_builder_detection() -> None:
    _, options = invoke(
        ["-s", "x86_64-linux", "123"], builders="ssh://builder aarch64-linux - 4 100 - - -"
    )

    assert options.systems == "x86_64-linux"


def test_preserves_review_choices_and_exit_status() -> None:
    status, options = invoke(
        ["-p", "-a", "-t", "-C", "-i", "122", "-i", "121", "123", "124"], status=7
    )

    assert status == 7
    assert options.request == ReviewRequest(
        pull_requests=("123", "124"),
        included_pull_requests=("122", "121"),
        post_result=True,
        approve=True,
        tests=True,
        cuda=True,
    )


def test_leaves_unconfigured_builders_to_nix() -> None:
    _, options = invoke(["123"])

    assert options.builders is None


def test_local_builds_exclude_community_builders() -> None:
    local_builders = "ssh-ng://fleet-builder x86_64-linux - 4 100 - - -"
    _, options = invoke(
        ["-l", "123"],
        builders=f"{local_builders} ; ssh-ng://community-builder aarch64-linux - 4 100 - - -",
        local_builders=local_builders,
    )

    assert options.systems == "x86_64-linux aarch64-darwin"
    assert options.builders == local_builders


def test_local_with_an_empty_pool_disables_configured_builders() -> None:
    _, options = invoke(["-l", "123"])

    assert options.builders == ""


@pytest.mark.parametrize(
    ("platform", "arguments", "builders", "build_arguments", "expected_runs"),
    [
        ("darwin", ["123"], MAC_BUILDERS, [], 1),
        ("darwin", ["-s", "all", "123"], MAC_BUILDERS, [], 1),
        ("darwin", ["-s", "x86_64-linux", "123"], MAC_BUILDERS, [], 0),
        ("darwin", ["-s", "aarch64-linux", "123"], "ssh-ng://remote aarch64-linux", [], 0),
        ("darwin", ["123"], MAC_BUILDERS, ["--builders", ""], 0),
        ("darwin", ["123"], MAC_BUILDERS, ["--option", "builders", ""], 0),
        ("linux", ["123"], MAC_BUILDERS, [], 0),
    ],
)
def test_guest_cleanup_only_runs_for_reviews_using_the_mac_builder(
    platform: str,
    arguments: list[str],
    builders: str,
    build_arguments: list[str],
    expected_runs: int,
) -> None:
    _, options = invoke(arguments, builders=builders)
    runner = RecordingGcRunner()

    prepare_mac_linux_builder(options, build_arguments, runner, platform=platform)

    assert runner.runs == expected_runs


def test_guest_cleanup_reports_errors() -> None:
    _, options = invoke(["-s", "aarch64-linux", "123"], builders=MAC_BUILDERS)

    with pytest.raises(RuntimeError, match="authentication failed"):
        prepare_mac_linux_builder(options, [], RecordingGcRunner(status=1), platform="darwin")
