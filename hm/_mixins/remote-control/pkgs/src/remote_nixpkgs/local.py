import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from typing import TextIO

from remote_nixpkgs.cli import ArgumentParser, UsageError
from remote_nixpkgs.runner import normalize_flake_ref
from remote_nixpkgs.runtime import ProcessController, RunError, SystemProcessController


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
    process: ProcessController | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = ArgumentParser(
        prog="run-nixpkgs",
        description="Run a nixpkgs PR package's mainProgram locally.",
    )
    parser.add_argument("--allow-unfree", action="store_true")
    parser.add_argument("source", help="PR number, GitHub PR URL, or flake reference")
    parser.add_argument("package_attribute")
    parser.add_argument("program_arguments", nargs=argparse.REMAINDER)
    try:
        options = parser.parse_args(argv)
    except UsageError as error:
        print(f"run-nixpkgs: {error}", file=stderr)
        print(parser.format_usage(), end="", file=stderr)
        return 64

    environ = dict(os.environ if environment is None else environment)
    arguments = ["nix", "--extra-experimental-features", "nix-command flakes", "run"]
    allow_unfree = environ.get("RUN_NIXPKGS_ALLOW_UNFREE", "").lower() in {"1", "true", "yes"}
    if options.allow_unfree or allow_unfree:
        arguments.append("--impure")
        environ["NIXPKGS_ALLOW_UNFREE"] = "1"

    program_arguments = options.program_arguments
    if program_arguments[:1] == ["--"]:
        program_arguments = program_arguments[1:]
    installable = f"{normalize_flake_ref(options.source)}#{options.package_attribute}"
    arguments.extend([installable, "--", *program_arguments])

    try:
        (process or SystemProcessController()).replace(arguments, environ)
    except RunError as error:
        print(f"run-nixpkgs: {error}", file=stderr)
        return 1
