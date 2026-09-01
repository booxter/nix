from __future__ import annotations

import os
from pathlib import Path

import pytest
from nix_builder_metrics.linux import CgroupSource, enable_accounting_controllers
from nix_builder_metrics.model import MetricsError


class FakeControl:
    def __init__(self, processes: list[bool], available: frozenset[str]) -> None:
        self.processes = processes
        self.available_controllers = available
        self.enabled_controllers: frozenset[str] = frozenset()

    def has_processes(self) -> bool:
        return self.processes.pop(0) if self.processes else False

    def available(self) -> frozenset[str]:
        return self.available_controllers

    def enable(self, controllers: frozenset[str]) -> None:
        self.enabled_controllers = controllers

    def enabled(self) -> frozenset[str]:
        return self.enabled_controllers


class FakeClock:
    now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


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


def test_enables_all_available_controllers_after_daemon_moves() -> None:
    control = FakeControl([True, False], frozenset({"cpu", "io", "memory", "pids"}))

    enable_accounting_controllers(control, FakeClock())

    assert control.enabled_controllers == frozenset({"cpu", "io", "memory", "pids"})


def test_requires_memory_and_io_controllers() -> None:
    control = FakeControl([False], frozenset({"cpu", "memory"}))

    with pytest.raises(MetricsError, match="required cgroup controllers are unavailable: io"):
        enable_accounting_controllers(control, FakeClock())


def test_times_out_while_daemon_remains_in_root() -> None:
    control = FakeControl([True, True, True], frozenset({"io", "memory"}))

    with pytest.raises(MetricsError, match="Nix daemon did not leave"):
        enable_accounting_controllers(control, FakeClock(), timeout_seconds=0.1)
