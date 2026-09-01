from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import pytest
from nix_builder_metrics.darwin import PsSource, parse_duration
from nix_builder_metrics.model import MetricsError


class FakePsRunner:
    def __init__(self, output: str) -> None:
        self.output = output

    def run(self, executable: Path, arguments: Sequence[str]) -> str:
        assert executable == Path("/bin/ps")
        assert arguments == ["-axo", "uid=,ppid=,etime=,time=,rss="]
        return self.output


def test_samples_build_user_processes() -> None:
    source = PsSource(
        Path("/bin/ps"),
        {300, 301},
        FakePsRunner(
            "300 10 01:02 00:12.50 100\n"
            "300 10 02:03 00:02.25 20\n"
            "301 11 1-01:00:00 01:00 30\n"
            "501 12 09:00 09:00 999\n"
            "300 1 10:00 00:01 500\n"
        ),
    )

    sample = source.sample()

    assert sample.active_slots == 2
    assert sample.processes == 3
    assert sample.cpu_seconds == 74.75
    assert sample.memory_bytes == 150 * 1024
    assert sample.memory_peak_bytes == 0
    assert sample.oldest_slot_seconds == 90000


def test_rejects_invalid_duration() -> None:
    with pytest.raises(MetricsError, match="invalid ps duration"):
        parse_duration("1")
