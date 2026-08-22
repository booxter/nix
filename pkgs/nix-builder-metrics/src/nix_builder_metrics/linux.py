from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Protocol

from .model import MetricsError, Sample

BUILD_CGROUP = re.compile(r"nix-build-(?:uid|pid)-[0-9]+(?:-[0-9]+)?$")
REQUIRED_CONTROLLERS = frozenset({"io", "memory"})
ACCOUNTING_CONTROLLERS = frozenset({"cpu", "io", "memory", "pids"})


class CgroupControl(Protocol):
    def has_processes(self) -> bool: ...

    def available(self) -> frozenset[str]: ...

    def enable(self, controllers: frozenset[str]) -> None: ...

    def enabled(self) -> frozenset[str]: ...


class Clock(Protocol):
    def monotonic(self) -> float: ...

    def sleep(self, seconds: float) -> None: ...


class SystemClock:
    def monotonic(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


class PathCgroupControl:
    def __init__(self, root: Path) -> None:
        self._root = root

    def has_processes(self) -> bool:
        return bool((self._root / "cgroup.procs").read_text().strip())

    def available(self) -> frozenset[str]:
        return frozenset((self._root / "cgroup.controllers").read_text().split())

    def enable(self, controllers: frozenset[str]) -> None:
        operations = " ".join(f"+{controller}" for controller in sorted(controllers))
        (self._root / "cgroup.subtree_control").write_text(f"{operations}\n")

    def enabled(self) -> frozenset[str]:
        return frozenset(
            controller.lstrip("+")
            for controller in (self._root / "cgroup.subtree_control").read_text().split()
        )


def enable_accounting_controllers(
    control: CgroupControl,
    clock: Clock,
    *,
    timeout_seconds: float = 5.0,
) -> None:
    deadline = clock.monotonic() + timeout_seconds
    while control.has_processes():
        if clock.monotonic() >= deadline:
            raise MetricsError("Nix daemon did not leave its service cgroup")
        clock.sleep(0.05)

    available = control.available()
    missing = REQUIRED_CONTROLLERS - available
    if missing:
        raise MetricsError(
            f"required cgroup controllers are unavailable: {' '.join(sorted(missing))}"
        )
    control.enable(available & ACCOUNTING_CONTROLLERS)
    missing = REQUIRED_CONTROLLERS - control.enabled()
    if missing:
        raise MetricsError(f"failed to enable cgroup controllers: {' '.join(sorted(missing))}")


def _keyed_values(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in path.read_text().splitlines():
        key, value = line.split()
        values[key] = int(value)
    return values


def _process_count(path: Path) -> int:
    return sum(len(procs.read_text().splitlines()) for procs in path.rglob("cgroup.procs"))


def _io_bytes(path: Path) -> tuple[int, int]:
    read_bytes = 0
    write_bytes = 0
    for line in path.read_text().splitlines():
        for field in line.split()[1:]:
            key, value = field.split("=", 1)
            if key == "rbytes":
                read_bytes += int(value)
            elif key == "wbytes":
                write_bytes += int(value)
    return read_bytes, write_bytes


class CgroupSource:
    def __init__(self, root: Path) -> None:
        self._root = root

    def sample(self) -> Sample:
        if not (self._root / "nix-daemon" / "cgroup.procs").is_file():
            raise MetricsError(f"Nix daemon cgroup is absent below {self._root}")

        now = time.time()
        builds = sorted(
            path
            for path in self._root.iterdir()
            if path.is_dir() and BUILD_CGROUP.fullmatch(path.name)
        )
        processes = 0
        cpu_seconds = 0.0
        memory_bytes = 0
        memory_peak_bytes = 0
        io_read_bytes = 0
        io_write_bytes = 0
        oldest_slot_seconds = 0.0

        for build in builds:
            processes += _process_count(build)
            cpu_seconds += _keyed_values(build / "cpu.stat")["usage_usec"] / 1_000_000
            memory_bytes += int((build / "memory.current").read_text().strip())
            memory_peak_bytes += int((build / "memory.peak").read_text().strip())
            read_bytes, write_bytes = _io_bytes(build / "io.stat")
            io_read_bytes += read_bytes
            io_write_bytes += write_bytes
            oldest_slot_seconds = max(oldest_slot_seconds, now - build.stat().st_ctime)

        return Sample(
            active_slots=len(builds),
            processes=processes,
            cpu_seconds=cpu_seconds,
            memory_bytes=memory_bytes,
            memory_peak_bytes=memory_peak_bytes,
            io_read_bytes=io_read_bytes,
            io_write_bytes=io_write_bytes,
            oldest_slot_seconds=oldest_slot_seconds,
        )
