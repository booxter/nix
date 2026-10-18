import argparse
import shlex
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Annotated, Protocol

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

DEFAULT_SYSTEMS = ("x86_64-linux", "aarch64-darwin")
AARCH64_LINUX_SYSTEMS = ("x86_64-linux", "aarch64-linux", "aarch64-darwin")
PullRequest = Annotated[str, StringConstraints(min_length=1, pattern=r"^[^-\s]")]


class ReviewRequest(BaseModel):
    """User choices, before applying the machine's builder configuration."""

    model_config = ConfigDict(frozen=True, extra="forbid", strict=True)

    pull_requests: Annotated[tuple[PullRequest, ...], Field(min_length=1)]
    included_pull_requests: tuple[PullRequest, ...] = ()
    extra_arguments: tuple[str, ...] = ()
    systems: str | None = None
    post_result: bool = False
    approve: bool = False
    tests: bool = False
    cuda: bool = False
    local: bool = False


@dataclass(frozen=True)
class ReviewOptions:
    request: ReviewRequest
    systems: str
    builders: str | None


class ReviewExecutor(Protocol):
    def run(self, options: ReviewOptions) -> int: ...


class NixpkgsReviewExecutor:
    def run(self, options: ReviewOptions) -> int:
        # Use the supported CLI so nixpkgs-review's Nix runtime wrapper applies.
        return subprocess.run(review_arguments(options), check=False).returncode


def builder_systems(builders: str) -> set[str]:
    systems: set[str] = set()
    for builder in builders.split(";"):
        fields = builder.split()
        if len(fields) >= 2:
            systems.update(fields[1].split(","))
    return systems


def resolve_review(request: ReviewRequest, environment: Mapping[str, str]) -> ReviewOptions:
    key = "NR_LOCAL_BUILDERS" if request.local else "NR_BUILDERS"
    builders = environment.get(key, "")
    defaults = (
        AARCH64_LINUX_SYSTEMS if "aarch64-linux" in builder_systems(builders) else DEFAULT_SYSTEMS
    )
    return ReviewOptions(
        request=request,
        systems=request.systems or " ".join(defaults),
        builders=builders if request.local or builders else None,
    )


def split_build_arguments(extra_arguments: tuple[str, ...]) -> tuple[list[str], list[str]]:
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False, exit_on_error=False)
    parser.add_argument("--build-args", action="append", default=[])
    try:
        supplied, review_arguments = parser.parse_known_args(extra_arguments)
    except argparse.ArgumentError as error:
        raise ValueError(str(error)) from error

    build_arguments: list[str] = []
    for value in supplied.build_args:
        build_arguments.extend(shlex.split(value))
    return review_arguments, build_arguments


def review_arguments(options: ReviewOptions) -> list[str]:
    request = options.request
    extra_arguments, supplied_build_arguments = split_build_arguments(request.extra_arguments)
    build_arguments = []
    if options.builders is not None:
        build_arguments.extend(["--builders", options.builders])
    # Keep explicit Nix options last so they can override fleet defaults.
    build_arguments.extend(supplied_build_arguments)

    # Match nixpkgs-review 3.9's initial evaluation when it recreates the review shell.
    nixpkgs_config = ["allowBroken = false;"]
    if request.cuda:
        nixpkgs_config.append("cudaSupport = true;")

    arguments = [
        "nixpkgs-review",
        "pr",
        *request.pull_requests,
        f"--extra-nixpkgs-config={{ {' '.join(nixpkgs_config)} }}",
        *extra_arguments,
        "--no-shell",
    ]
    for pull_request in request.included_pull_requests:
        arguments.extend(("--include-pr", pull_request))
    if request.post_result:
        arguments.append("--post-result")
    if request.approve:
        arguments.append("--approve-pr")
    if request.tests:
        arguments.append("--tests")
    arguments.append(f"--systems={options.systems}")
    if build_arguments:
        arguments.append(f"--build-args={shlex.join(build_arguments)}")
    return arguments
