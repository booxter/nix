from __future__ import annotations

from typing import Protocol

from pystemd.systemd1 import Unit


def duration_from_timestamps(start: int, end: int) -> float:
    if start <= 0 or end <= 0 or end < start:
        return 0.0
    return (end - start) / 1_000_000


class DurationSource(Protocol):
    def duration_seconds(self, unit_name: str) -> float: ...


class SystemdDurationSource:
    def duration_seconds(self, unit_name: str) -> float:
        try:
            with Unit(unit_name.encode()) as unit:
                return duration_from_timestamps(
                    unit.Service.ExecMainStartTimestampMonotonic,
                    unit.Service.ExecMainExitTimestampMonotonic,
                )
        except Exception:
            # Outcome recording is best effort during ExecStopPost. A missing
            # property or unavailable system bus should not mask the service's
            # original result.
            return 0.0
