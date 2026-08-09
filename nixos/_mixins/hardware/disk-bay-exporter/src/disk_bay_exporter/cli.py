from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from pydantic import ValidationError

from .exporter import DiskBayExporter, LsblkSource, SubprocessCommandRunner


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="disk-bay-metrics",
        description="Export physical disk-bay mappings.",
    )
    result.add_argument("--bay-map", required=True, type=Path)
    result.add_argument("--output-file", required=True, type=Path)
    return result


def main(
    argv: Sequence[str] | None = None,
    exporter: DiskBayExporter | None = None,
) -> int:
    arguments = parser().parse_args(argv if argv is not None else sys.argv[1:])
    collector = exporter or DiskBayExporter(LsblkSource(SubprocessCommandRunner()))
    try:
        collector.run(arguments.bay_map, arguments.output_file)
    except (OSError, ValidationError) as error:
        print(f"disk-bay-metrics: {error}", file=sys.stderr)
        return 1
    return 0
