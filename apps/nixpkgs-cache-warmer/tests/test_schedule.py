import io
from pathlib import Path
from typing import TextIO

from nixpkgs_cache_warmer.build import BuildOutcome
from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageTarget, ResolvedSource
from nixpkgs_cache_warmer.schedule import Schedule, ScheduledTarget
from nixpkgs_cache_warmer.warmer import WarmOutcome


class FakeWarmer:
    def __init__(self, failures: set[ScheduledTarget]) -> None:
        self.failures = failures
        self.visited: list[ScheduledTarget] = []

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
        target = ScheduledTarget(reference=reference, system=system)
        self.visited.append(target)
        if target in self.failures:
            raise CommandError("build failed")
        return WarmOutcome(
            resolved=ResolvedSource(
                reference=reference,
                revision="012345",
                source=Path("/source"),
            ),
            build=BuildOutcome(successful=(), failed=(), outputs=()),
            published_caches=caches,
        )


def test_continues_through_the_complete_matrix_after_failure() -> None:
    failed_target = ScheduledTarget("staging", "x86_64-linux")
    warmer = FakeWarmer({failed_target})

    outcome = Schedule(warmer).run(
        ("master", "staging"),
        "booxter",
        ("aarch64-darwin", "x86_64-linux"),
        ("firefox.*", "thunderbird.*"),
        (),
        ("central:nix",),
        io.StringIO(),
    )

    assert warmer.visited == [
        ScheduledTarget("master", "aarch64-darwin"),
        ScheduledTarget("master", "x86_64-linux"),
        ScheduledTarget("staging", "aarch64-darwin"),
        ScheduledTarget("staging", "x86_64-linux"),
    ]
    assert outcome.failed == (failed_target,)


class PartialWarmer(FakeWarmer):
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
        outcome = super().warm(
            reference,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
            caches,
            log,
        )
        broken = PackageTarget(
            drvPath=Path("/nix/store/broken.drv"),
            name="broken-1",
            pname="broken",
            outputs=(Path("/nix/store/broken"),),
        )
        return WarmOutcome(
            resolved=outcome.resolved,
            build=BuildOutcome(successful=(), failed=(broken,), outputs=()),
            published_caches=outcome.published_caches,
        )


def test_package_failures_do_not_fail_the_schedule() -> None:
    outcome = Schedule(PartialWarmer(set())).run(
        ("staging",),
        "booxter",
        ("x86_64-linux",),
        (),
        (),
        ("central:nix",),
        io.StringIO(),
    )

    assert outcome.failed == ()
