from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from nixpkgs_cache_warmer.commands import CommandError, CommandRunner, SubprocessCommandRunner
from nixpkgs_cache_warmer.inventory import Inventory
from nixpkgs_cache_warmer.resolver import SourceResolver


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="nixpkgs-cache-warmer")
    subparsers = result.add_subparsers(dest="command", required=True)
    targets = subparsers.add_parser("targets", help="print maintained package build targets")
    targets.add_argument("--source", required=True, type=Path)
    targets.add_argument("--maintainer", required=True)
    targets.add_argument("--system", required=True)
    targets.add_argument("--exclude-pname-pattern", action="append", default=[])
    targets.add_argument("--json", action="store_true")
    resolve = subparsers.add_parser("resolve", help="resolve a flake reference immutably")
    resolve.add_argument("reference")
    resolve.add_argument("--json", action="store_true")
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
        if arguments.command == "resolve":
            resolved = SourceResolver(runner, Path(environ["NIXPKGS_CACHE_WARMER_NIX"])).resolve(
                arguments.reference
            )
            if arguments.json:
                stdout.write(resolved.model_dump_json(indent=2) + "\n")
            else:
                print(f"{resolved.revision}\t{resolved.source}", file=stdout)
            return 0

        targets = Inventory(
            runner,
            Path(environ["NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE"]),
            Path(environ["NIXPKGS_CACHE_WARMER_INVENTORY_EXPR"]),
        ).targets(
            arguments.source,
            arguments.maintainer,
            arguments.system,
            tuple(arguments.exclude_pname_pattern),
        )
    except KeyError as error:
        print(f"nixpkgs-cache-warmer: missing packaged setting: {error.args[0]}", file=stderr)
        return 2
    except CommandError as error:
        print(f"nixpkgs-cache-warmer: {error}", file=stderr)
        return 1

    if arguments.json:
        json.dump([target.model_dump(mode="json") for target in targets], stdout, indent=2)
        stdout.write("\n")
    else:
        for target in targets:
            print(f"{target.pname}\t{target.drvPath}", file=stdout)
    return 0


def main() -> int:
    return run(sys.argv[1:], os.environ, SubprocessCommandRunner(), sys.stdout, sys.stderr)
