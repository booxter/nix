from __future__ import annotations

import argparse
import pwd
import re
import sys
from collections.abc import Sequence
from pathlib import Path

from .darwin import PsSource, SubprocessPsRunner
from .exporter import write_metrics
from .linux import PathCgroupControl, CgroupSource, SystemClock, enable_accounting_controllers
from .model import MetricsError, Sample, SampleSource

BUILD_USER = re.compile(r"_?nixbld[0-9]+$")
EMPTY_SAMPLE = Sample(0, 0, 0.0, 0, 0, 0, 0, 0.0)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="nix-builder-metrics",
        description="Export active Nix builder metrics for node_exporter.",
    )
    result.add_argument("--configured-slots", type=int, required=True)
    result.add_argument("--output-file", type=Path, required=True)
    sources = result.add_mutually_exclusive_group(required=True)
    sources.add_argument("--cgroup-root", type=Path)
    sources.add_argument("--darwin-ps", type=Path)
    return result


def _source(arguments: argparse.Namespace) -> SampleSource:
    if arguments.cgroup_root is not None:
        return CgroupSource(arguments.cgroup_root)
    build_uids = {entry.pw_uid for entry in pwd.getpwall() if BUILD_USER.fullmatch(entry.pw_name)}
    if not build_uids:
        raise MetricsError("no Nix build users found")
    return PsSource(arguments.darwin_ps, build_uids, SubprocessPsRunner())


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        sample = _source(arguments).sample()
    except (MetricsError, OSError, ValueError) as error:
        write_metrics(
            arguments.output_file, arguments.configured_slots, EMPTY_SAMPLE, success=False
        )
        print(f"nix-builder-metrics: {error}", file=sys.stderr)
        return 1
    write_metrics(arguments.output_file, arguments.configured_slots, sample, success=True)
    return 0


def setup_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="nix-builder-cgroup-setup",
        description="Enable delegated accounting controllers for Nix build cgroups.",
    )
    result.add_argument("--cgroup-root", type=Path, required=True)
    return result


def setup_main(argv: Sequence[str] | None = None) -> int:
    arguments = setup_parser().parse_args(argv if argv is not None else sys.argv[1:])
    try:
        enable_accounting_controllers(PathCgroupControl(arguments.cgroup_root), SystemClock())
    except (MetricsError, OSError) as error:
        print(f"nix-builder-cgroup-setup: {error}", file=sys.stderr)
        return 1
    return 0
