import argparse
import shlex
import subprocess
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Protocol

from nr.process import CommandRunner, ProcessRunner, checked
from pydantic import BaseModel, ConfigDict, Field, StringConstraints

DEFAULT_SYSTEMS = ("x86_64-linux", "aarch64-darwin")
AARCH64_LINUX_SYSTEMS = ("x86_64-linux", "aarch64-linux", "aarch64-darwin")
ARM_LINUX_SYSTEM_NAMES = {"aarch64-linux", "all", "linux", "aarch64", "arm64"}
MAC_LINUX_BUILDER = "ssh-ng://builder@linux-builder"
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
        extra_arguments, supplied_build_arguments = split_build_arguments(
            options.request.extra_arguments
        )
        arguments = review_arguments(options, extra_arguments, supplied_build_arguments)
        prepare_mac_linux_builder(options, supplied_build_arguments, ProcessRunner())
        # Use the supported CLI so nixpkgs-review's Nix runtime wrapper applies.
        return subprocess.run(arguments, check=False).returncode


def effective_builders(builders: str, arguments: list[str]) -> str:
    arguments_iter = iter(arguments)
    for argument in arguments_iter:
        if argument == "--builders":
            builders = next(arguments_iter, "")
        elif argument == "--option":
            name = next(arguments_iter, "")
            value = next(arguments_iter, "")
            if name == "builders":
                builders = value
    return builders


def prepare_mac_linux_builder(
    options: ReviewOptions,
    supplied_build_arguments: list[str],
    runner: CommandRunner,
    *,
    platform: str = sys.platform,
) -> None:
    if platform != "darwin" or ARM_LINUX_SYSTEM_NAMES.isdisjoint(options.systems.split()):
        return

    builders = effective_builders(options.builders or "", supplied_build_arguments)
    if not any(
        fields[0] == MAC_LINUX_BUILDER and "aarch64-linux" in fields[1].split(",")
        for record in builders.split(";")
        if len(fields := record.split()) >= 2
    ):
        return

    # The VM's client key is root-owned. Use the calling user's known host key.
    known_hosts = Path.home() / ".ssh" / "known_hosts"
    print("nr: collecting garbage on linux-builder", file=sys.stderr, flush=True)
    result = runner.run(
        [
            "/usr/bin/sudo",
            "/usr/bin/ssh",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "BatchMode=yes",
            "linux-builder",
            "nix-store --store daemon --gc --max-freed 8G --quiet",
        ]
    )
    if summary := checked(result):
        print(summary, file=sys.stderr, flush=True)


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


def review_arguments(
    options: ReviewOptions, extra_arguments: list[str], supplied_build_arguments: list[str]
) -> list[str]:
    request = options.request
    build_arguments = []
    if options.builders is not None:
        build_arguments.extend(["--builders", options.builders])
    # Keep explicit Nix options last so they can override fleet defaults.
    build_arguments.extend(supplied_build_arguments)

    arguments = [
        "nixpkgs-review",
        "pr",
        *request.pull_requests,
        *extra_arguments,
        "--no-shell",
    ]
    for pull_request in request.included_pull_requests:
        arguments.extend(("--include-pr", pull_request))
    if request.cuda:
        arguments.append("--extra-nixpkgs-config={ cudaSupport = true; }")
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
