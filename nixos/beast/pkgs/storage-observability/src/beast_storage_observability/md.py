from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

PREFIX = "host_observability_md_"
ACTION_TITLES = {
    "idle": "Idle",
    "reshape": "Reshape",
    "recover": "Recover",
    "recovering": "Recovering",
    "resync": "Resync",
    "check": "Check",
    "repair": "Repair",
    "frozen": "Frozen",
}


def read(path: Path, default: str = "") -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return default


def integer(value: str, default: int = 0) -> int:
    try:
        return int(value.split(maxsplit=1)[0])
    except (ValueError, IndexError):
        return default


def sync_progress(value: str) -> tuple[int, int]:
    fields = value.split()
    if len(fields) < 3 or fields[1] != "/":
        return 0, 0
    return integer(fields[0]), integer(fields[2])


def raid_disk_counts(value: str) -> tuple[int, int]:
    current = integer(value)
    match = re.search(r"\((\d+)\)", value)
    return current, int(match.group(1)) if match else current


class MdMetrics:
    def __init__(self) -> None:
        self.registry = CollectorRegistry()
        self.action_info = self.gauge(
            "sync_action_info",
            "Current md background action for the array.",
            ("device", "action", "action_title"),
        )
        self.active = self.gauge(
            "sync_active",
            "Whether the md array currently has background work active.",
            ("device", "action"),
        )
        self.progress = self.gauge(
            "sync_progress_percent",
            "Current md background work completion percentage.",
            ("device", "action"),
        )
        self.completed = self.gauge(
            "sync_completed_sectors",
            "Current md background work completed sectors.",
            ("device", "action"),
        )
        self.total = self.gauge(
            "sync_total_sectors",
            "Current md background work total sectors.",
            ("device", "action"),
        )
        self.speed = self.gauge(
            "sync_speed_bytes_per_second",
            "Estimated md background work speed in bytes per second.",
            ("device", "action"),
        )
        self.eta = self.gauge(
            "sync_eta_seconds",
            "Estimated md background work remaining time in seconds.",
            ("device", "action"),
        )
        self.raid_disks = self.gauge(
            "raid_disks",
            "Current and previous md raid disk counts during reshape.",
            ("device", "phase"),
        )
        self.degraded = self.gauge(
            "degraded",
            "Current md degraded member count.",
            ("device",),
        )

    def gauge(self, suffix: str, documentation: str, labels: tuple[str, ...]) -> Gauge:
        return Gauge(PREFIX + suffix, documentation, labels, registry=self.registry)

    def collect_array(self, directory: Path) -> None:
        device = directory.parent.name
        action = read(directory / "sync_action", "idle")
        title = ACTION_TITLES.get(action, action)
        active = action != "idle"
        degraded = integer(read(directory / "degraded"))
        completed, total = sync_progress(read(directory / "sync_completed"))
        progress = 100 * completed / total if total > 0 else 0
        speed_kib = integer(read(directory / "sync_speed"))
        speed_bytes = speed_kib * 1024
        eta = (
            round((total - completed) / (2 * speed_kib))
            if active and speed_kib > 0 and total > completed
            else 0
        )
        current_disks, previous_disks = raid_disk_counts(read(directory / "raid_disks"))

        action_labels = (device, action)
        self.action_info.labels(device, action, title).set(1)
        self.active.labels(*action_labels).set(1 if active else 0)
        self.progress.labels(*action_labels).set(progress)
        self.completed.labels(*action_labels).set(completed)
        self.total.labels(*action_labels).set(total)
        self.speed.labels(*action_labels).set(speed_bytes)
        self.eta.labels(*action_labels).set(eta)
        self.raid_disks.labels(device, "current").set(current_disks)
        self.raid_disks.labels(device, "previous").set(previous_disks)
        self.degraded.labels(device).set(degraded)


@dataclass(frozen=True)
class MdExporter:
    sys_block_root: Path = Path("/sys/block")

    def run(self, output_path: Path) -> None:
        metrics = MdMetrics()
        for directory in sorted(self.sys_block_root.glob("md*/md")):
            metrics.collect_array(directory)
        write_text_atomic(
            output_path,
            generate_latest(metrics.registry).decode("utf-8"),
            mode=0o644,
        )
