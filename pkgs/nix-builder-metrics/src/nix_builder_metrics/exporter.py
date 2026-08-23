from __future__ import annotations

import time
from pathlib import Path

from atomic_file_writes import write_bytes_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .model import Sample

PREFIX = "host_observability_nix_builder"


def write_metrics(
    output: Path,
    configured_slots: int,
    sample: Sample,
    *,
    success: bool,
) -> None:
    registry = CollectorRegistry()
    values: tuple[tuple[str, str, float], ...] = (
        ("configured_slots", "Configured concurrent Nix build slots.", configured_slots),
        ("active_slots", "Nix build slots currently active.", sample.active_slots),
        ("processes", "Processes in active Nix builds.", sample.processes),
        ("cpu_seconds", "CPU seconds consumed by active Nix builds.", sample.cpu_seconds),
        ("memory_bytes", "Current memory used by active Nix builds.", sample.memory_bytes),
        (
            "memory_peak_bytes",
            "Peak memory used by active Nix builds on Linux.",
            sample.memory_peak_bytes,
        ),
        ("io_read_bytes", "Bytes read by active Nix builds on Linux.", sample.io_read_bytes),
        ("io_write_bytes", "Bytes written by active Nix builds on Linux.", sample.io_write_bytes),
        (
            "oldest_active_slot_seconds",
            "Age of the oldest active Nix build slot.",
            sample.oldest_slot_seconds,
        ),
        ("collect_success", "Whether collection succeeded.", int(success)),
        ("sample_timestamp_seconds", "Unix timestamp of this metrics sample.", time.time()),
    )
    for suffix, documentation, value in values:
        Gauge(f"{PREFIX}_{suffix}", documentation, registry=registry).set(value)
    write_bytes_atomic(output, generate_latest(registry), create_mode=0o644)
