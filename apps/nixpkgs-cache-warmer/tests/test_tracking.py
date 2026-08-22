import io
from pathlib import Path
from typing import TextIO

import pytest

from nixpkgs_cache_warmer.build import BuildOutcome
from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageTarget, ResolvedSource, WarmerState
from nixpkgs_cache_warmer.tracking import TrackingWarmer
from nixpkgs_cache_warmer.warmer import WarmOutcome


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
    (),
)


class FakeStore:
    def __init__(self) -> None:
        self.state = WarmerState()

    def read(self) -> WarmerState:
        return self.state

    def write(self, state: WarmerState) -> None:
        self.state = state


class SuccessfulWarmer:
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
        return OUTCOME


class FailingWarmer:
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
        raise CommandError("network unavailable")


def test_tracks_completed_attempt() -> None:
    store = FakeStore()
    outcome = TrackingWarmer(SuccessfulWarmer(), store).warm(
        OUTCOME.resolved.reference,
        "booxter",
        "x86_64-linux",
        (),
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
            (),
            io.StringIO(),
        )

    assert store.state.targets[0].last_attempt.status == "failed"
    assert store.state.targets[0].last_attempt.error == "network unavailable"
