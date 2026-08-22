import io
from pathlib import Path
from typing import TextIO

import pytest

from nixpkgs_cache_warmer.build import BuildOutcome
from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageTarget, ResolvedSource, WarmerState
from nixpkgs_cache_warmer.tracking import TrackingWarmer
from nixpkgs_cache_warmer.warmer import WarmOutcome
from nixpkgs_cache_warmer.warmer import PreparationFailure, PreparationOutcome, PreparedTarget


TARGET = PackageTarget(
    drvPath=Path("/nix/store/one.drv"),
    name="one-1",
    pname="one",
    outputs=(Path("/nix/store/one"),),
)
OUTCOME = WarmOutcome(
    ResolvedSource(
        reference="github:NixOS/nixpkgs/staging",
        revision="012345",
        source=Path("/nix/store/source"),
    ),
    BuildOutcome((TARGET,), (), TARGET.outputs),
)


class FakeStore:
    def __init__(self) -> None:
        self.state = WarmerState()
        self.writes = 0

    def read(self) -> WarmerState:
        return self.state

    def write(self, state: WarmerState) -> None:
        self.writes += 1
        self.state = state


class SuccessfulWarmer:
    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome:
        return OUTCOME


class FailingWarmer:
    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome:
        raise CommandError("network unavailable")


class MatrixWarmer(SuccessfulWarmer):
    def __init__(self, fail_build: bool = False) -> None:
        self.fail_build = fail_build
        self.prepared = (
            PreparedTarget(OUTCOME.resolved, "aarch64-darwin", (TARGET,)),
            PreparedTarget(OUTCOME.resolved, "x86_64-linux", (TARGET,)),
        )

    def prepare_matrix(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> PreparationOutcome:
        return PreparationOutcome(
            prepared=self.prepared,
            failed=(PreparationFailure("master", "x86_64-linux", "resolution failed"),),
        )

    def build_matrix(
        self, prepared_targets: tuple[PreparedTarget, ...], log: TextIO
    ) -> tuple[WarmOutcome, ...]:
        if self.fail_build:
            raise CommandError("build unavailable")
        return (OUTCOME, OUTCOME)


def test_tracks_completed_attempt() -> None:
    store = FakeStore()
    outcome = TrackingWarmer(SuccessfulWarmer(), store).warm(
        OUTCOME.resolved.reference,
        "booxter",
        "x86_64-linux",
        (),
        (),
        io.StringIO(),
    )

    assert outcome == OUTCOME
    assert store.state.targets[0].last_success is not None
    assert store.state.targets[0].last_success.revision == "012345"


def test_tracks_command_failure_before_reraising() -> None:
    store = FakeStore()
    with pytest.raises(CommandError, match="network unavailable"):
        TrackingWarmer(FailingWarmer(), store).warm(
            OUTCOME.resolved.reference,
            "booxter",
            "x86_64-linux",
            (),
            (),
            io.StringIO(),
        )

    assert store.state.targets[0].last_attempt.status == "failed"
    assert store.state.targets[0].last_attempt.error == "network unavailable"


def test_tracks_complete_matrix_with_one_state_write() -> None:
    store = FakeStore()

    outcome = TrackingWarmer(MatrixWarmer(), store).warm_matrix(
        ("master",),
        "booxter",
        ("aarch64-darwin", "x86_64-linux"),
        (),
        (),
        io.StringIO(),
    )

    assert len(outcome.completed) == 2
    assert outcome.failed == (PreparationFailure("master", "x86_64-linux", "resolution failed"),)
    assert store.writes == 1
    assert [(target.reference, target.system) for target in store.state.targets] == [
        (OUTCOME.resolved.reference, "aarch64-darwin"),
        (OUTCOME.resolved.reference, "x86_64-linux"),
        ("master", "x86_64-linux"),
    ]


def test_tracks_all_prepared_targets_when_matrix_build_fails() -> None:
    store = FakeStore()

    with pytest.raises(CommandError, match="build unavailable"):
        TrackingWarmer(MatrixWarmer(fail_build=True), store).warm_matrix(
            ("master",),
            "booxter",
            ("aarch64-darwin", "x86_64-linux"),
            (),
            (),
            io.StringIO(),
        )

    assert store.writes == 1
    assert all(target.last_attempt.status == "failed" for target in store.state.targets)
