from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from .hba import HbaError, HbaExporter, SubprocessStorcliSource
from .maintenance import guard_raid
from .md import MdExporter


def hba_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="storage-storcli-metrics",
        description="Export StorCLI HBA metrics for node_exporter textfile collection.",
    )
    parser.add_argument("--bay-map", required=True, type=Path)
    parser.add_argument("--output-file", required=True, type=Path)
    return parser


def hba_main(argv: Sequence[str] | None = None) -> int:
    arguments = hba_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        HbaExporter(SubprocessStorcliSource()).run(arguments.bay_map, arguments.output_file)
    except HbaError as error:
        print(f"storage-storcli-metrics: {error}", file=sys.stderr)
        return 1
    return 0


def md_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="storage-md-metrics",
        description="Export MD sync metrics for node_exporter textfile collection.",
    )
    parser.add_argument("--output-file", required=True, type=Path)
    return parser


def md_main(argv: Sequence[str] | None = None) -> int:
    arguments = md_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        MdExporter().run(arguments.output_file)
    except OSError as error:
        print(f"storage-md-metrics: {error}", file=sys.stderr)
        return 1
    return 0


def maintenance_main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="storage-md-maintenance",
        description="Skip unattended maintenance while an MD reshape is unfinished.",
    )
    parser.add_argument("--sys-block", type=Path, default=Path("/sys/block"))
    arguments = parser.parse_args(argv if argv is not None else sys.argv[1:])
    try:
        return guard_raid(arguments.sys_block, sys.stderr)
    except (OSError, ValueError) as error:
        print(f"storage-md-maintenance: {error}", file=sys.stderr)
        return 1
