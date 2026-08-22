from __future__ import annotations

from datetime import datetime, timezone
from typing import Protocol, TextIO

from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import WarmerState
from nixpkgs_cache_warmer.state import completed_record, failed_record, update_state
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


class StateRepository(Protocol):
    def read(self) -> WarmerState: ...

    def write(self, state: WarmerState) -> None: ...


class TrackingWarmer:
    def __init__(self, warmer: WarmOperation, store: StateRepository) -> None:
        self._warmer = warmer
        self._store = store

    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        caches: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome:
        state = self._store.read()
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
            self._store.write(
                update_state(
                    state,
                    reference,
                    system,
                    failed_record(datetime.now(timezone.utc), str(error)),
                )
            )
            raise
        self._store.write(
            update_state(
                state,
                reference,
                system,
                completed_record(outcome, datetime.now(timezone.utc)),
            )
        )
        return outcome
