from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from nixpkgs_cache_warmer.build import NixBuilder
from nixpkgs_cache_warmer.commands import CommandError, CommandRunner, SubprocessCommandRunner
from nixpkgs_cache_warmer.inventory import Inventory
from nixpkgs_cache_warmer.models import WarmerState
from nixpkgs_cache_warmer.resolver import SourceResolver
from nixpkgs_cache_warmer.schedule import Schedule
from nixpkgs_cache_warmer.state import RemoteStateReader, StateStore
from nixpkgs_cache_warmer.tracking import TrackingWarmer
from nixpkgs_cache_warmer.warmer import Warmer


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="nixpkgs-cache-warmer")
    subparsers = result.add_subparsers(dest="command", required=True)
    targets = subparsers.add_parser("targets", help="print maintained package build targets")
    targets.add_argument("--source", required=True, type=Path)
    targets.add_argument("--maintainer", required=True)
    targets.add_argument("--system", required=True)
    targets.add_argument("--exclude-pname-pattern", action="append", default=[])
    targets.add_argument("--include-pname-pattern", action="append", default=[])
    targets.add_argument("--json", action="store_true")
    resolve = subparsers.add_parser("resolve", help="resolve a flake reference immutably")
    resolve.add_argument("reference")
    resolve.add_argument("--json", action="store_true")
    warm = subparsers.add_parser("warm", help="build maintained packages for one flake reference")
    warm.add_argument("reference")
    warm.add_argument("--maintainer", required=True)
    warm.add_argument("--system", required=True)
    warm.add_argument("--exclude-pname-pattern", action="append", default=[])
    warm.add_argument("--include-pname-pattern", action="append", default=[])
    warm.add_argument("--state-file", type=Path)
    scheduled = subparsers.add_parser("run", help="warm a branch and system matrix")
    scheduled.add_argument("--reference", action="append", required=True)
    scheduled.add_argument("--maintainer", required=True)
    scheduled.add_argument("--system", action="append", required=True)
    scheduled.add_argument("--exclude-pname-pattern", action="append", default=[])
    scheduled.add_argument("--include-pname-pattern", action="append", default=[])
    scheduled.add_argument("--state-file", type=Path)
    status = subparsers.add_parser("status", help="show persisted warming status")
    status.add_argument("--state-file", type=Path)
    location = status.add_mutually_exclusive_group()
    location.add_argument("--host")
    location.add_argument("--local", action="store_true")
    status.add_argument("--branch")
    status.add_argument("--system")
    status.add_argument("--json", action="store_true")
    status.add_argument("--print-revision", action="store_true")
    return result


def run(
    argv: Sequence[str],
    environ: Mapping[str, str],
    runner: CommandRunner,
    stdout: TextIO,
    stderr: TextIO,
) -> int:
    arguments = parser().parse_args(argv)
    try:
        state_file = (
            arguments.state_file or Path(environ["NIXPKGS_CACHE_WARMER_STATE_FILE"])
            if arguments.command in ("status", "warm", "run")
            else None
        )
        if arguments.command == "status":
            assert state_file is not None
            runner_host = arguments.host or environ.get("NIXPKGS_CACHE_WARMER_RUNNER", "")
            state = (
                RemoteStateReader(
                    runner,
                    Path(environ["NIXPKGS_CACHE_WARMER_SSH"]),
                    runner_host,
                    state_file,
                ).read()
                if runner_host and not arguments.local
                else StateStore(state_file).read()
            )
            status_targets = tuple(
                status_target
                for status_target in state.targets
                if (
                    arguments.branch is None
                    or status_target.reference.rsplit("/", 1)[-1] == arguments.branch
                )
                and (arguments.system is None or status_target.system == arguments.system)
            )
            if arguments.print_revision:
                if len(status_targets) != 1 or status_targets[0].last_success is None:
                    raise CommandError(
                        "revision output requires exactly one successful matching target"
                    )
                print(status_targets[0].last_success.revision, file=stdout)
            elif arguments.json:
                stdout.write(WarmerState(targets=status_targets).model_dump_json(indent=2) + "\n")
            else:
                for status_target in status_targets:
                    attempt = status_target.last_attempt
                    success = status_target.last_success
                    print(
                        f"{status_target.reference.rsplit('/', 1)[-1]}\t{status_target.system}\t"
                        f"{attempt.revision or '-'}\t{attempt.status}\t"
                        f"{attempt.built}/{attempt.selected}\t"
                        f"last-success={success.revision if success is not None else '-'}",
                        file=stdout,
                    )
            return 0

        if arguments.command in ("warm", "run"):
            assert state_file is not None
            nix = Path(environ["NIXPKGS_CACHE_WARMER_NIX"])
            warmer = TrackingWarmer(
                Warmer(
                    SourceResolver(runner, nix),
                    Inventory(
                        runner,
                        Path(environ["NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE"]),
                        Path(environ["NIXPKGS_CACHE_WARMER_INVENTORY_EXPR"]),
                    ),
                    NixBuilder(runner, nix),
                ),
                StateStore(
                    state_file,
                    Path(environ["NIXPKGS_CACHE_WARMER_METRICS_FILE"])
                    if environ.get("NIXPKGS_CACHE_WARMER_METRICS_FILE")
                    else None,
                ),
            )
            if arguments.command == "run":
                schedule_outcome = Schedule(warmer).run(
                    tuple(arguments.reference),
                    arguments.maintainer,
                    tuple(arguments.system),
                    tuple(arguments.exclude_pname_pattern),
                    tuple(arguments.include_pname_pattern),
                    stderr,
                )
                return 1 if schedule_outcome.failed else 0
            outcome = warmer.warm(
                arguments.reference,
                arguments.maintainer,
                arguments.system,
                tuple(arguments.exclude_pname_pattern),
                tuple(arguments.include_pname_pattern),
                stderr,
            )
            return 1 if outcome.build.failed else 0

        if arguments.command == "resolve":
            resolved = SourceResolver(runner, Path(environ["NIXPKGS_CACHE_WARMER_NIX"])).resolve(
                arguments.reference
            )
            if arguments.json:
                stdout.write(resolved.model_dump_json(indent=2) + "\n")
            else:
                print(f"{resolved.revision}\t{resolved.source}", file=stdout)
            return 0

        package_targets = Inventory(
            runner,
            Path(environ["NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE"]),
            Path(environ["NIXPKGS_CACHE_WARMER_INVENTORY_EXPR"]),
        ).targets(
            arguments.source,
            arguments.maintainer,
            arguments.system,
            tuple(arguments.exclude_pname_pattern),
            tuple(arguments.include_pname_pattern),
        )
    except KeyError as error:
        print(f"nixpkgs-cache-warmer: missing packaged setting: {error.args[0]}", file=stderr)
        return 2
    except CommandError as error:
        print(f"nixpkgs-cache-warmer: {error}", file=stderr)
        return 1

    if arguments.json:
        json.dump(
            [package_target.model_dump(mode="json") for package_target in package_targets],
            stdout,
            indent=2,
        )
        stdout.write("\n")
    else:
        for package_target in package_targets:
            print(f"{package_target.pname}\t{package_target.drvPath}", file=stdout)
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:], os.environ, SubprocessCommandRunner(), sys.stdout, sys.stderr)
    except KeyboardInterrupt:
        return 130
