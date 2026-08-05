from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import BayMapping, BayMappings


class LsbkSource(Protocol):
    def collect(self) -> dict[str, str]:
        """Return a mapping from disk serial to device name (e.g. {"ZYD0CASB": "sda"})."""


@dataclass(frozen=True)
class SubprocessLsbkSource:
    executable: str = "lsblk"

    def collect(self) -> dict[str, str]:
        result = subprocess.run(
            [self.executable, "-dn", "-o", "NAME,SERIAL"],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return {}
        mapping: dict[str, str] = {}
        for line in result.stdout.strip().splitlines():
            if not line.strip():
                continue
            parts = line.strip().split()
            if len(parts) >= 2 and parts[1]:
                mapping[parts[1]] = parts[0]
        return mapping


class DiskBayMetrics:
    def __init__(self) -> None:
        self.registry = CollectorRegistry()
        self.info = Gauge(
            "host_observability_disk_bay_info",
            "Current mapping of beast disk device names to physical bays.",
            ("device", "bay", "bay_row", "bay_col", "serial", "model"),
            registry=self.registry,
        )

    def collect(self, device: str, mapping: BayMapping) -> None:
        self.info.labels(
            device,
            str(mapping.bay),
            str(mapping.row),
            str(mapping.col),
            mapping.serial,
            mapping.model,
        ).set(1)


@dataclass(frozen=True)
class DiskBayExporter:
    source: LsbkSource

    def run(self, bay_map: Path, output_path: Path) -> None:
        mappings = BayMappings.model_validate_json(bay_map.read_text(encoding="utf-8"))
        by_serial = mappings.by_serial()
        serial_to_device = self.source.collect()
        metrics = DiskBayMetrics()
        for serial, mapping in by_serial.items():
            device = serial_to_device.get(serial)
            if device is not None:
                metrics.collect(device, mapping)
        write_text_atomic(
            output_path,
            generate_latest(metrics.registry).decode("utf-8"),
            mode=0o644,
        )
