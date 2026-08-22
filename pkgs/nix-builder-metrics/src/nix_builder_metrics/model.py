from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


class MetricsError(Exception):
    """The platform metrics source could not produce a trustworthy sample."""


@dataclass(frozen=True)
class Sample:
    active_slots: int
    processes: int
    cpu_seconds: float
    memory_bytes: int
    memory_peak_bytes: int
    io_read_bytes: int
    io_write_bytes: int
    oldest_slot_seconds: float


class SampleSource(Protocol):
    def sample(self) -> Sample: ...
