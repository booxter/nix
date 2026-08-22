import io
from typing import TextIO

from nixpkgs_cache_warmer.schedule import Schedule, ScheduledTarget
from nixpkgs_cache_warmer.tracking import MatrixTrackingOutcome
from nixpkgs_cache_warmer.warmer import PreparationFailure


class FakeWarmer:
    def __init__(self, failures: tuple[PreparationFailure, ...]) -> None:
        self.failures = failures
        self.calls: list[
            tuple[
                tuple[str, ...],
                str,
                tuple[str, ...],
                tuple[str, ...],
                tuple[str, ...],
            ]
        ] = []

    def warm_matrix(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> MatrixTrackingOutcome:
        self.calls.append(
            (
                references,
                maintainer,
                systems,
                exclude_pname_patterns,
                include_pname_patterns,
            )
        )
        return MatrixTrackingOutcome(completed=(), failed=self.failures)


def test_submits_complete_matrix_as_one_operation() -> None:
    failure = PreparationFailure("staging", "x86_64-linux", "build failed")
    warmer = FakeWarmer((failure,))

    outcome = Schedule(warmer).run(
        ("master", "staging"),
        "booxter",
        ("aarch64-darwin", "x86_64-linux"),
        ("firefox.*", "thunderbird.*"),
        ("one",),
        io.StringIO(),
    )

    assert warmer.calls == [
        (
            ("master", "staging"),
            "booxter",
            ("aarch64-darwin", "x86_64-linux"),
            ("firefox.*", "thunderbird.*"),
            ("one",),
        )
    ]
    assert outcome.failed == (ScheduledTarget("staging", "x86_64-linux"),)
