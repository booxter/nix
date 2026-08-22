from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Protocol, TextIO

from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import WarmerState
from nixpkgs_cache_warmer.state import completed_record, failed_record, update_state
from nixpkgs_cache_warmer.warmer import (
    PreparationFailure,
    PreparationOutcome,
    PreparedTarget,
    WarmOutcome,
)


class WarmOperation(Protocol):
    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome: ...

    def prepare_matrix(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> PreparationOutcome: ...

    def build_matrix(
        self, prepared_targets: tuple[PreparedTarget, ...], log: TextIO
    ) -> tuple[WarmOutcome, ...]: ...


class StateRepository(Protocol):
    def read(self) -> WarmerState: ...

    def write(self, state: WarmerState) -> None: ...


@dataclass(frozen=True)
class MatrixTrackingOutcome:
    completed: tuple[tuple[PreparedTarget, WarmOutcome], ...]
    failed: tuple[PreparationFailure, ...]


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

    def warm_matrix(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> MatrixTrackingOutcome:
        state = self._store.read()
        preparation = self._warmer.prepare_matrix(
            references,
            maintainer,
            systems,
            exclude_pname_patterns,
            include_pname_patterns,
            log,
        )
        for failure in preparation.failed:
            print(
                f"Failed {failure.reference} for {failure.system}: {failure.error}",
                file=log,
            )
        try:
            outcomes = self._warmer.build_matrix(preparation.prepared, log)
        except CommandError as error:
            now = datetime.now(timezone.utc)
            for failure in preparation.failed:
                state = update_state(
                    state,
                    failure.reference,
                    failure.system,
                    failed_record(now, failure.error),
                )
            for prepared in preparation.prepared:
                state = update_state(
                    state,
                    prepared.resolved.reference,
                    prepared.system,
                    failed_record(now, str(error)),
                )
            self._store.write(state)
            raise
        assert len(outcomes) == len(preparation.prepared)
        now = datetime.now(timezone.utc)
        for failure in preparation.failed:
            state = update_state(
                state,
                failure.reference,
                failure.system,
                failed_record(now, failure.error),
            )
        completed = tuple(zip(preparation.prepared, outcomes, strict=True))
        for prepared, outcome in completed:
            state = update_state(
                state,
                prepared.resolved.reference,
                prepared.system,
                completed_record(outcome, now),
            )
        self._store.write(state)
        return MatrixTrackingOutcome(completed=completed, failed=preparation.failed)
