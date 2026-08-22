from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, TextIO

from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.warmer import WarmOutcome


class WarmOperation(Protocol):
    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        caches: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome: ...


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
        caches: tuple[str, ...],
        log: TextIO,
    ) -> ScheduleOutcome:
        failed = []
        for reference in references:
            for system in systems:
                target = ScheduledTarget(reference=reference, system=system)
                print(f"Starting {reference} for {system}", file=log)
                try:
                    outcome = self._warmer.warm(
                        reference,
                        maintainer,
                        system,
                        exclude_pname_patterns,
                        include_pname_patterns,
                        caches,
                        log,
                    )
                except CommandError as error:
                    print(f"Failed {reference} for {system}: {error}", file=log)
                    failed.append(target)
                    continue
                if outcome.build.failed:
                    failed.append(target)
        return ScheduleOutcome(failed=tuple(failed))
