from collections.abc import Sequence

from nr.cli import main
from nr.review import ReviewOptions, ReviewRequest


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
