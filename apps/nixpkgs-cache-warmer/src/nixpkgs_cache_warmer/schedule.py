from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, TextIO

from nixpkgs_cache_warmer.tracking import MatrixTrackingOutcome


class WarmOperation(Protocol):
    def warm_matrix(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> MatrixTrackingOutcome: ...


@dataclass(frozen=True)
class ScheduledTarget:
    reference: str
    system: str


@dataclass(frozen=True)
class ScheduleOutcome:
    failed: tuple[ScheduledTarget, ...]


class Schedule:
    def __init__(self, warmer: WarmOperation) -> None:
        self._warmer = warmer

    def run(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> ScheduleOutcome:
        outcome = self._warmer.warm_matrix(
            references,
            maintainer,
            systems,
            exclude_pname_patterns,
            include_pname_patterns,
            log,
        )
        return ScheduleOutcome(
            failed=tuple(
                ScheduledTarget(reference=failure.reference, system=failure.system)
                for failure in outcome.failed
            )
        )
