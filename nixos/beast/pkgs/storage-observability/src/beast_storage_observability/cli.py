from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from pydantic import ValidationError

from .disk_bays import DiskBayExporter, SubprocessLsbkSource
from .hba import HbaError, HbaExporter, SubprocessStorcliSource
from .md import MdExporter


def disk_bay_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="beast-disk-bay-metrics",
        description="Export Beast physical disk bay mappings.",
    )
    parser.add_argument("--bay-map", required=True, type=Path)
    parser.add_argument("--output-file", required=True, type=Path)
    return parser


def disk_bay_main(
    argv: Sequence[str] | None = None,
    exporter: DiskBayExporter | None = None,
) -> int:
    arguments = disk_bay_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        (exporter or DiskBayExporter(SubprocessLsbkSource())).run(
            arguments.bay_map, arguments.output_file
        )
    except (OSError, ValidationError) as error:
        print(f"beast-disk-bay-metrics: {error}", file=sys.stderr)
        return 1
    return 0


def hba_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="beast-hba-metrics",
        description="Export Beast HBA metrics for node_exporter textfile collection.",
    )
    parser.add_argument("--bay-map", required=True, type=Path)
    parser.add_argument("--output-file", required=True, type=Path)
    return parser


def hba_main(argv: Sequence[str] | None = None) -> int:
    arguments = hba_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        HbaExporter(SubprocessStorcliSource()).run(arguments.bay_map, arguments.output_file)
    except HbaError as error:
        print(f"beast-hba-metrics: {error}", file=sys.stderr)
        return 1
    return 0


def md_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="beast-md-metrics",
        description="Export Beast md sync metrics for node_exporter textfile collection.",
    )
    parser.add_argument("--output-file", required=True, type=Path)
    return parser


def md_main(argv: Sequence[str] | None = None) -> int:
    arguments = md_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        MdExporter().run(arguments.output_file)
    except OSError as error:
        print(f"beast-md-metrics: {error}", file=sys.stderr)
        return 1
    return 0
