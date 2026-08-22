from __future__ import annotations

import os
from pathlib import Path

import pytest

from nix_builder_metrics.linux import CgroupSource
from nix_builder_metrics.model import MetricsError


def write_cgroup(path: Path, *, cpu: int, memory: int, peak: int, procs: str, io: str) -> None:
    path.mkdir()
    (path / "cpu.stat").write_text(f"usage_usec {cpu}\nuser_usec 1\n")
    (path / "memory.current").write_text(f"{memory}\n")
    (path / "memory.peak").write_text(f"{peak}\n")
    (path / "cgroup.procs").write_text(procs)
    (path / "io.stat").write_text(io)


def test_samples_live_nix_cgroups(tmp_path: Path) -> None:
    daemon = tmp_path / "nix-daemon"
    daemon.mkdir()
    (daemon / "cgroup.procs").write_text("10\n")
    write_cgroup(
        tmp_path / "nix-build-uid-872415232",
        cpu=1_500_000,
        memory=100,
        peak=150,
        procs="20\n21\n",
        io="8:0 rbytes=100 wbytes=200 rios=1 wios=2\n8:1 rbytes=3 wbytes=4\n",
    )
    write_cgroup(
        tmp_path / "nix-build-pid-99-0",
        cpu=500_000,
        memory=50,
        peak=75,
        procs="22\n",
        io="8:0 rbytes=7 wbytes=9\n",
    )
    os.mkdir(tmp_path / "unrelated")

    sample = CgroupSource(tmp_path).sample()

    assert sample.active_slots == 2
    assert sample.processes == 3
    assert sample.cpu_seconds == 2.0
    assert sample.memory_bytes == 150
    assert sample.memory_peak_bytes == 225
    assert sample.io_read_bytes == 110
    assert sample.io_write_bytes == 213
    assert sample.oldest_slot_seconds >= 0


def test_requires_nix_daemon_cgroup(tmp_path: Path) -> None:
    with pytest.raises(MetricsError, match="Nix daemon cgroup is absent"):
        CgroupSource(tmp_path).sample()
