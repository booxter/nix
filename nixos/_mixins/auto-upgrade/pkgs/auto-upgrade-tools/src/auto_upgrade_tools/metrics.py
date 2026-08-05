from __future__ import annotations

import time
from datetime import date, datetime, time as datetime_time
from pathlib import Path

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .model import UpgradeConfig, UpgradeHold


def _local_epoch(day: date, clock: datetime_time) -> int:
    return int(time.mktime(datetime.combine(day, clock).timetuple()))


def hold_metric_text(config: UpgradeConfig, today: date) -> str:
    registry = CollectorRegistry()
    active = Gauge(
        "node_nixos_upgrade_hold_active",
        "Whether NixOS auto-upgrade is currently suppressed by a declared hold.",
        registry=registry,
    )
    start = Gauge(
        "node_nixos_upgrade_hold_start_time_seconds",
        "Unix time for the active NixOS auto-upgrade hold start, or 0 when no hold is active.",
        registry=registry,
    )
    stop = Gauge(
        "node_nixos_upgrade_hold_stop_time_seconds",
        "Unix time for the active NixOS auto-upgrade hold stop, or 0 when no hold is active.",
        registry=registry,
    )
    hold = config.active_hold(today)
    active.set(hold is not None)
    start.set(_local_epoch(hold.start_date, datetime_time.min) if hold else 0)
    stop.set(_local_epoch(hold.stop_date, datetime_time(23, 59, 59)) if hold else 0)
    return generate_latest(registry).decode("utf-8")


def write_hold_metrics(path: Path, config: UpgradeConfig, today: date) -> None:
    write_text_atomic(path, hold_metric_text(config, today), mode=0o644)


def success_metric_text(timestamp: int) -> str:
    registry = CollectorRegistry()
    success = Gauge(
        "node_nixos_upgrade_last_success_time_seconds",
        "Unix time of the last successful nixos-upgrade.service run.",
        registry=registry,
    )
    success.set(timestamp)
    return generate_latest(registry).decode("utf-8")


def write_success_metric(path: Path, timestamp: int) -> None:
    write_text_atomic(path, success_metric_text(timestamp), mode=0o644)


def hold_description(hostname: str, today: date, hold: UpgradeHold) -> str:
    return (
        f"Skipping NixOS auto-upgrade maintenance on {hostname}: {today.isoformat()} "
        f"is within hold {hold.start_date.isoformat()}..{hold.stop_date.isoformat()}."
    )
