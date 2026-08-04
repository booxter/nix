from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import BayMapping, BayMappings


def read_serial(block_device: Path) -> str:
    try:
        return (block_device / "device/serial").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


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
    sys_block_root: Path = Path("/sys/block")

    def run(self, bay_map: Path, output_path: Path) -> None:
        mappings = BayMappings.model_validate_json(bay_map.read_text(encoding="utf-8"))
        by_serial = mappings.by_serial()
        metrics = DiskBayMetrics()
        for block_device in sorted(self.sys_block_root.iterdir()):
            serial = read_serial(block_device)
            mapping = by_serial.get(serial)
            if mapping is not None:
                metrics.collect(block_device.name, mapping)
        write_text_atomic(
            output_path,
            generate_latest(metrics.registry).decode("utf-8"),
            mode=0o644,
        )
