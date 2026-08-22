from datetime import datetime, timezone
from pathlib import Path

import pytest

from nixpkgs_cache_warmer.build import BuildOutcome
from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageTarget, ResolvedSource, TargetState, WarmerState
from nixpkgs_cache_warmer.state import StateStore, completed_record, failed_record, update_state
from nixpkgs_cache_warmer.warmer import WarmOutcome


NOW = datetime(2026, 8, 21, 5, 0, tzinfo=timezone.utc)
TARGET = PackageTarget(
    drvPath=Path("/nix/store/one.drv"),
    name="one-1",
    pname="one",
    outputs=(Path("/nix/store/one"),),
)
RESOLVED = ResolvedSource(
    reference="github:NixOS/nixpkgs/staging",
    revision="012345",
    source=Path("/nix/store/source"),
)


def test_successful_attempt_becomes_last_success() -> None:
    record = completed_record(
        WarmOutcome(RESOLVED, BuildOutcome((TARGET,), (), TARGET.outputs), ("home:default",)),
        NOW,
    )
    state = update_state(WarmerState(), RESOLVED.reference, "x86_64-linux", record)

    assert state.targets[0].last_attempt.revision == "012345"
    assert state.targets[0].last_success == record
    assert state.targets[0].last_attempt.pushed == 1


def test_partial_attempt_advances_completed_revision() -> None:
    success = completed_record(
        WarmOutcome(RESOLVED, BuildOutcome((TARGET,), (), TARGET.outputs), ()), NOW
    )
    previous = update_state(WarmerState(), RESOLVED.reference, "x86_64-linux", success)
    partial = completed_record(WarmOutcome(RESOLVED, BuildOutcome((), (TARGET,), ()), ()), NOW)

    updated = update_state(previous, RESOLVED.reference, "x86_64-linux", partial)

    assert updated.targets[0].last_attempt.status == "partial"
    assert updated.targets[0].last_success == partial
    assert updated.targets[0].last_attempt.error == "failed packages: one"


def test_failed_attempt_without_revision_preserves_previous_success() -> None:
    success = completed_record(
        WarmOutcome(RESOLVED, BuildOutcome((TARGET,), (), TARGET.outputs), ()), NOW
    )
    previous = update_state(WarmerState(), RESOLVED.reference, "x86_64-linux", success)

    updated = update_state(
        previous,
        RESOLVED.reference,
        "x86_64-linux",
        failed_record(NOW, "network unavailable"),
    )

    assert updated.targets[0].last_attempt.revision is None
    assert updated.targets[0].last_success == success


def test_store_round_trips_atomically_with_public_mode(tmp_path: Path) -> None:
    path = tmp_path / "state" / "status.json"
    store = StateStore(path)
    state = update_state(
        WarmerState(),
        RESOLVED.reference,
        "x86_64-linux",
        failed_record(NOW, "failed"),
    )

    store.write(state)

    assert store.read() == state
    assert path.stat().st_mode & 0o777 == 0o644


def test_store_treats_partial_build_as_operational_success_in_metrics(tmp_path: Path) -> None:
    state_path = tmp_path / "status.json"
    metrics_path = tmp_path / "textfile" / "warmer.prom"
    record = completed_record(WarmOutcome(RESOLVED, BuildOutcome((), (TARGET,), ()), ()), NOW)
    state = WarmerState(
        targets=(
            TargetState(
                reference=RESOLVED.reference,
                system="x86_64-linux",
                last_attempt=record,
                last_success=record,
            ),
        )
    )

    StateStore(state_path, metrics_path).write(state)

    metrics = metrics_path.read_text()
    labels = 'branch="staging",system="x86_64-linux"'
    assert f"last_attempt_success{{{labels}}} 1" in metrics
    assert f"last_success_timestamp_seconds{{{labels}}} {NOW.timestamp():.0f}" in metrics
    assert f'last_success_revision_info{{{labels},revision="012345"}} 1' in metrics
    assert metrics_path.stat().st_mode & 0o777 == 0o644


def test_store_rejects_invalid_state(tmp_path: Path) -> None:
    path = tmp_path / "status.json"
    path.write_text('{"schema_version": 2}')
    with pytest.raises(CommandError, match="invalid warmer state"):
        StateStore(path).read()
