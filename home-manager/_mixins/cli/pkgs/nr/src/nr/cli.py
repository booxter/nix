import argparse
import os
import shlex
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol


DEFAULT_SYSTEMS = ("x86_64-linux", "aarch64-darwin")
AARCH64_LINUX_SYSTEMS = ("x86_64-linux", "aarch64-linux", "aarch64-darwin")


class ReviewExecutor(Protocol):
    def run(self, arguments: Sequence[str]) -> int: ...


class NixpkgsReviewExecutor:
    def run(self, arguments: Sequence[str]) -> int:
        # The wrapped CLI is nixpkgs-review's supported interface. Importing
        # its private Python entry point would bypass its Nix runtime wrapper.
        return subprocess.run(arguments, check=False).returncode


@dataclass(frozen=True)
class ReviewOptions:
    pull_requests: tuple[str, ...]
    included_pull_requests: tuple[str, ...]
    systems: str
    post_result: bool
    approve: bool
    tests: bool
    cuda: bool
    builders: str


def builder_systems(builders: str) -> set[str]:
    systems: set[str] = set()
    for builder in builders.split(";"):
        fields = builder.split()
        if len(fields) >= 2:
            systems.update(fields[1].split(","))
    return systems


def default_systems(builders: str) -> tuple[str, ...]:
    if "aarch64-linux" in builder_systems(builders):
        return AARCH64_LINUX_SYSTEMS
    return DEFAULT_SYSTEMS


def review_arguments(options: ReviewOptions) -> list[str]:
    arguments = ["nixpkgs-review", "pr", *options.pull_requests, "--no-shell"]
    for pull_request in options.included_pull_requests:
        arguments.extend(("--include-pr", pull_request))
    if options.cuda:
        arguments.append("--extra-nixpkgs-config={ cudaSupport = true; }")
    if options.post_result:
        arguments.append("--post-result")
    if options.approve:
        arguments.append("--approve-pr")
    if options.tests:
        arguments.append("--tests")
    arguments.append(f"--systems={options.systems}")
    if options.builders:
        build_arguments = shlex.join(["--builders", options.builders])
        arguments.append(f"--build-args={build_arguments}")
    return arguments


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nr",
        description="Review a nixpkgs pull request using the fleet's remote builders.",
    )
    parser.add_argument("-p", "--post-result", action="store_true")
    parser.add_argument("-a", "--approve", action="store_true")
    parser.add_argument("-t", "--tests", action="store_true")
    parser.add_argument("-i", "--include-pr", action="append", default=[])
    parser.add_argument("-s", "--systems")
    parser.add_argument("-C", "--cuda", action="store_true")
    parser.add_argument("pull_requests", nargs="+")
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
    executor: ReviewExecutor | None = None,
) -> int:
    arguments = _parser().parse_args(argv)
    environ = os.environ if environment is None else environment
    builders = environ.get("NR_BUILDERS", "")
    systems = arguments.systems or " ".join(default_systems(builders))
    options = ReviewOptions(
        pull_requests=tuple(arguments.pull_requests),
        included_pull_requests=tuple(arguments.include_pr),
        systems=systems,
        post_result=arguments.post_result,
        approve=arguments.approve,
        tests=arguments.tests,
        cuda=arguments.cuda,
        builders=builders,
    )
    return (executor or NixpkgsReviewExecutor()).run(review_arguments(options))
