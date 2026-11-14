from __future__ import annotations

import argparse
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest


class Source(Protocol):
    def read(self, path: Path) -> str: ...


class Filesystem:
    def read(self, path: Path) -> str:
        return path.read_text()

    def resolve_groups(self, root: Path, patterns: Sequence[str]) -> list[str]:
        groups: set[str] = set()
        for pattern in patterns:
            if "*" in pattern:
                groups.update(
                    str(path.relative_to(root)) for path in root.glob(pattern) if path.is_dir()
                )
            else:
                groups.add(pattern)
        return sorted(groups)


@dataclass(frozen=True)
class Memory:
    charged: int
    mapped: int
    unmapped: int


def read_memory(source: Source, group: Path) -> Memory:
    stats = {
        key: int(value)
        for key, value in (line.split() for line in source.read(group / "memory.stat").splitlines())
    }
    # Match Senpai's estimate, excluding shared memory and ordinary swapcache.
    unmapped = max(
        0,
        stats["active_anon"]
        + stats["inactive_anon"]
        - stats["anon"]
        - stats["shmem"]
        - stats.get("swapcached", 0),
    )
    return Memory(int(source.read(group / "memory.current")), stats["anon"], unmapped)


def collect(source: Source, root: Path, groups: Sequence[str]) -> str:
    registry = CollectorRegistry()
    up = Gauge(
        "memory_reclaim_cgroup_up",
        "Whether the target cgroup exists",
        ["cgroup"],
        registry=registry,
    )
    memory = Gauge(
        "memory_reclaim_bytes",
        "Cgroup memory accounting; unmapped is an estimate",
        ["cgroup", "kind"],
        registry=registry,
    )
    pressure = Gauge(
        "memory_reclaim_stall_seconds_total",
        "Cumulative cgroup PSI stall seconds",
        ["cgroup", "resource", "kind"],
        registry=registry,
    )
    for name in groups:
        group = root / name
        try:
            sample = read_memory(source, group)
            # Read all files before emitting so a disappearing cgroup has no
            # stale partial sample in the replacement textfile.
            stalls: list[tuple[str, str, float]] = []
            for resource in ("memory", "io"):
                for line in source.read(group / f"{resource}.pressure").splitlines():
                    kind, *fields = line.split()
                    values = dict(field.split("=", 1) for field in fields)
                    stalls.append((resource, kind, int(values["total"]) / 1_000_000))
        except FileNotFoundError:
            up.labels(name).set(0)
            continue

        up.labels(name).set(1)
        for kind, value in (
            ("charged", sample.charged),
            ("mapped_anon", sample.mapped),
            ("unmapped_anon", sample.unmapped),
        ):
            memory.labels(name, kind).set(value)
        for resource, kind, seconds in stalls:
            pressure.labels(name, resource, kind).set(seconds)
    return generate_latest(registry).decode()


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Export memory retention and PSI for reclaim targets"
    )
    parser.add_argument("--cgroup-root", type=Path, default=Path("/sys/fs/cgroup"))
    parser.add_argument("--cgroup", action="append", required=True)
    parser.add_argument("--output-file", type=Path, required=True)
    args = parser.parse_args(argv)
    source = Filesystem()
    groups = source.resolve_groups(args.cgroup_root, args.cgroup)
    output = collect(source, args.cgroup_root, groups)
    write_text_atomic(args.output_file, output, mode=0o644)
