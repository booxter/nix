from __future__ import annotations

import subprocess
from collections.abc import Collection, Sequence
from pathlib import Path
from typing import Protocol

from .model import MetricsError, Sample


def parse_duration(value: str) -> float:
    day_parts = value.split("-", 1)
    days = int(day_parts[0]) if len(day_parts) == 2 else 0
    clock = day_parts[-1].split(":")
    if len(clock) == 3:
        hours, minutes, seconds = clock
    elif len(clock) == 2:
        hours = "0"
        minutes, seconds = clock
    else:
        raise MetricsError(f"invalid ps duration: {value}")
    return days * 86400 + int(hours) * 3600 + int(minutes) * 60 + float(seconds)


class PsRunner(Protocol):
    def run(self, executable: Path, arguments: Sequence[str]) -> str: ...


class SubprocessPsRunner:
    def run(self, executable: Path, arguments: Sequence[str]) -> str:
        result = subprocess.run(
            [str(executable), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise MetricsError(result.stderr.strip() or f"ps exited with {result.returncode}")
        return result.stdout


class PsSource:
    def __init__(self, executable: Path, build_uids: Collection[int], runner: PsRunner) -> None:
        self._executable = executable
        self._build_uids = frozenset(build_uids)
        self._runner = runner

    def sample(self) -> Sample:
        active_uids: set[int] = set()
        processes = 0
        cpu_seconds = 0.0
        memory_bytes = 0
        oldest_slot_seconds = 0.0
        arguments = ["-axo", "uid=,etime=,time=,rss="]
        for line in self._runner.run(self._executable, arguments).splitlines():
            fields = line.split()
            if len(fields) != 4:
                raise MetricsError(f"invalid ps output line: {line}")
            uid = int(fields[0])
            if uid not in self._build_uids:
                continue
            active_uids.add(uid)
            processes += 1
            oldest_slot_seconds = max(oldest_slot_seconds, parse_duration(fields[1]))
            cpu_seconds += parse_duration(fields[2])
            memory_bytes += int(fields[3]) * 1024

        return Sample(
            active_slots=len(active_uids),
            processes=processes,
            cpu_seconds=cpu_seconds,
            memory_bytes=memory_bytes,
            memory_peak_bytes=0,
            io_read_bytes=0,
            io_write_bytes=0,
            oldest_slot_seconds=oldest_slot_seconds,
        )
