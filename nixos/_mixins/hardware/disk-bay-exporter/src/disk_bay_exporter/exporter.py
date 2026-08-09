from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import BayMapping, BayMappings


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str


class CommandRunner(Protocol):
    def run(self, args: list[str]) -> CommandResult:
        """Run a command and return its exit status and standard output."""


@dataclass(frozen=True)
class SubprocessCommandRunner:
    def run(self, args: list[str]) -> CommandResult:
        result = subprocess.run(args, check=False, capture_output=True, text=True)
        return CommandResult(returncode=result.returncode, stdout=result.stdout)


class SerialDeviceSource(Protocol):
    def collect(self) -> dict[str, str]:
        """Map disk serials to kernel device names."""


@dataclass(frozen=True)
class LsblkSource:
    runner: CommandRunner
    executable: str = "lsblk"

    def collect(self) -> dict[str, str]:
        result = self.runner.run([self.executable, "-dn", "-o", "NAME,SERIAL"])
        if result.returncode != 0:
            return {}
        mapping: dict[str, str] = {}
        for line in result.stdout.strip().splitlines():
            parts = line.strip().split()
            if len(parts) >= 2 and parts[1]:
                mapping[parts[1]] = parts[0]
        return mapping


class DiskBayMetrics:
    def __init__(self) -> None:
        self.registry = CollectorRegistry()
        self.info = Gauge(
            "host_observability_disk_bay_info",
            "Current mapping of disk device names to physical bays.",
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
    source: SerialDeviceSource

    def run(self, bay_map: Path, output_path: Path) -> None:
        mappings = BayMappings.model_validate_json(bay_map.read_text(encoding="utf-8"))
        serial_to_device = self.source.collect()
        metrics = DiskBayMetrics()
        for serial, mapping in mappings.by_serial().items():
            device = serial_to_device.get(serial)
            if device is not None:
                metrics.collect(device, mapping)
        write_text_atomic(
            output_path,
            generate_latest(metrics.registry).decode("utf-8"),
            mode=0o644,
        )
