import io
from pathlib import Path
from typing import TextIO

import pytest

from nixpkgs_cache_warmer.build import BuildOutcome
from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageTarget, ResolvedSource
from nixpkgs_cache_warmer.warmer import PreparationFailure, PreparedTarget, Warmer


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


class FakeResolver:
    def resolve(self, reference: str) -> ResolvedSource:
        assert reference == RESOLVED.reference
        return RESOLVED


class MatrixResolver:
    def __init__(self, failed: set[str] | None = None) -> None:
        self.failed = failed or set()
        self.references: list[str] = []

    def resolve(self, reference: str) -> ResolvedSource:
        self.references.append(reference)
        if reference in self.failed:
            raise CommandError("resolution failed")
        return ResolvedSource(
            reference=reference,
            revision=f"{reference}-rev",
            source=Path("/source"),
        )


class FakeInventory:
    def __init__(self, targets: tuple[PackageTarget, ...]) -> None:
        self._targets = targets
        self.call: tuple[Path, str, str, tuple[str, ...], tuple[str, ...]] | None = None

    def instantiate(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]:
        self.call = (
            source,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
        )
        return self._targets


class MatrixInventory:
    def __init__(self, failed_systems: set[str] | None = None) -> None:
        self.failed_systems = failed_systems or set()

    def instantiate(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]:
        if system in self.failed_systems:
            raise CommandError("inventory failed")
        return (TARGET,)


class FakeBuilder:
    def __init__(self, outcome: BuildOutcome) -> None:
        self._outcome = outcome
        self.targets: tuple[PackageTarget, ...] | None = None

    def build(self, targets: tuple[PackageTarget, ...], log: TextIO) -> BuildOutcome:
        self.targets = targets
        return self._outcome


def test_warms_resolved_source_and_reports_success() -> None:
    inventory = FakeInventory((TARGET,))
    builder = FakeBuilder(BuildOutcome((TARGET,), (), TARGET.outputs))
    log = io.StringIO()

    outcome = Warmer(FakeResolver(), inventory, builder).warm(
        RESOLVED.reference,
        "booxter",
        "x86_64-linux",
        ("firefox.*",),
        ("one",),
        log,
    )

    assert outcome.resolved == RESOLVED
    assert outcome.build.successful == (TARGET,)
    assert inventory.call == (
        RESOLVED.source,
        "booxter",
        "x86_64-linux",
        ("firefox.*",),
        ("one",),
    )
    assert builder.targets == (TARGET,)
    assert "Built 1/1" in log.getvalue()


def test_prepares_packages_without_building() -> None:
    inventory = FakeInventory((TARGET,))
    builder = FakeBuilder(BuildOutcome((), (), ()))

    prepared = Warmer(FakeResolver(), inventory, builder).prepare(
        RESOLVED.reference,
        "booxter",
        "x86_64-linux",
        (),
        (),
        io.StringIO(),
    )

    assert prepared == PreparedTarget(RESOLVED, "x86_64-linux", (TARGET,))
    assert builder.targets is None


def test_prepares_matrix_with_one_resolution_per_reference() -> None:
    resolver = MatrixResolver()
    warmer = Warmer(resolver, MatrixInventory(), FakeBuilder(BuildOutcome((), (), ())))

    outcome = warmer.prepare_matrix(
        ("master", "staging"),
        "booxter",
        ("aarch64-darwin", "x86_64-linux"),
        (),
        (),
        io.StringIO(),
    )

    assert resolver.references == ["master", "staging"]
    assert [(target.resolved.reference, target.system) for target in outcome.prepared] == [
        ("master", "aarch64-darwin"),
        ("master", "x86_64-linux"),
        ("staging", "aarch64-darwin"),
        ("staging", "x86_64-linux"),
    ]
    assert outcome.failed == ()


def test_preparation_failures_do_not_abort_matrix() -> None:
    warmer = Warmer(
        MatrixResolver({"master"}),
        MatrixInventory({"aarch64-darwin"}),
        FakeBuilder(BuildOutcome((), (), ())),
    )

    outcome = warmer.prepare_matrix(
        ("master", "staging"),
        "booxter",
        ("aarch64-darwin", "x86_64-linux"),
        (),
        (),
        io.StringIO(),
    )

    assert [(target.resolved.reference, target.system) for target in outcome.prepared] == [
        ("staging", "x86_64-linux")
    ]
    assert outcome.failed == (
        PreparationFailure("master", "aarch64-darwin", "resolution failed"),
        PreparationFailure("master", "x86_64-linux", "resolution failed"),
        PreparationFailure("staging", "aarch64-darwin", "inventory failed"),
    )


def test_reports_partial_failure() -> None:
    log = io.StringIO()
    outcome = Warmer(
        FakeResolver(),
        FakeInventory((TARGET,)),
        FakeBuilder(BuildOutcome((), (TARGET,), ())),
    ).warm(RESOLVED.reference, "booxter", "x86_64-linux", (), (), log)

    assert outcome.build.failed == (TARGET,)
    assert "Failed: one" in log.getvalue()


def test_rejects_empty_inventory() -> None:
    with pytest.raises(CommandError, match="no maintained package targets"):
        Warmer(FakeResolver(), FakeInventory(()), FakeBuilder(BuildOutcome((), (), ()))).warm(
            RESOLVED.reference, "booxter", "x86_64-linux", (), (), io.StringIO()
        )
