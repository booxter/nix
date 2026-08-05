from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest
from pydantic import ValidationError

from .models import BayMapping, BayMappings, Drive, DriveBasic, StorcliDocument

PREFIX = "host_observability_hba_"
DRIVE_LABELS = (
    "bay",
    "bay_col",
    "bay_row",
    "controller",
    "controller_enclosure",
    "controller_slot",
    "model",
    "serial",
)


class HbaError(RuntimeError):
    """Expected HBA collection failure."""


class StorcliSource(Protocol):
    def collect(self) -> StorcliDocument: ...


@dataclass(frozen=True)
class SubprocessStorcliSource:
    executable: str = "storcli"

    def collect(self) -> StorcliDocument:
        try:
            result = subprocess.run(
                [self.executable, "/cALL", "show", "all", "J", "nolog"],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise HbaError(f"could not execute StorCLI: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "StorCLI failed"
            raise HbaError(detail)
        try:
            return StorcliDocument.model_validate_json(result.stdout)
        except ValidationError as error:
            raise HbaError(f"invalid StorCLI response: {error}") from error


def clean(value: object | None) -> str:
    return "" if value is None else str(value).strip()


def number(value: object | None) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = clean(value)
    if text in {"", "N/A", "NA", "Unknown", "-"}:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def matched_number(value: object | None, pattern: str) -> float | None:
    match = re.search(pattern, clean(value))
    return float(match.group(1)) if match else None


def object_map(value: object | None) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        return {}
    return cast(dict[str, object], value)


def drive_identifier(controller: str, enclosure: str, slot: str) -> str:
    if enclosure:
        return f"Drive /c{controller}/e{enclosure}/s{slot}"
    return f"Drive /c{controller}/s{slot}"


def visible_drive(
    controller: str,
    basic_value: object,
    details: dict[str, object],
    bay_mappings: dict[str, BayMapping],
) -> Drive | None:
    if not isinstance(basic_value, list) or not basic_value:
        return None
    try:
        basic = DriveBasic.model_validate(basic_value[0])
    except ValidationError:
        return None
    enclosure_slot = clean(basic.enclosure_slot)
    enclosure, separator, slot = enclosure_slot.partition(":")
    if not separator:
        enclosure, slot = "", enclosure
    enclosure = enclosure.strip()
    slot = slot.strip()
    drive_key = drive_identifier(controller, enclosure, slot)
    detail = object_map(details.get(f"{drive_key} - Detailed Information"))
    state = object_map(detail.get(f"{drive_key} State"))
    attributes = object_map(detail.get(f"{drive_key} Device attributes"))
    settings = object_map(detail.get(f"{drive_key} Policies/Settings"))
    serial = clean(attributes.get("SN"))
    mapping = bay_mappings.get(serial)
    smart_text = clean(state.get("S.M.A.R.T alert flagged by drive"))
    smart_alerted = {"Yes": 1.0, "No": 0.0}.get(smart_text)
    return Drive(
        controller=controller,
        controller_enclosure=enclosure,
        controller_slot=slot,
        disk_id=clean(basic.disk_id),
        interface=basic.interface.strip(),
        media=basic.media.strip(),
        model=clean(attributes.get("Model Number")) or basic.model.strip(),
        state=basic.state.strip(),
        firmware=clean(attributes.get("Firmware Revision")),
        serial=serial,
        bay=clean(mapping.bay) if mapping else "",
        bay_row=clean(mapping.row) if mapping else "",
        bay_col=clean(mapping.col) if mapping else "",
        link_speed_gbps=matched_number(
            attributes.get("Link Speed"), r"([0-9]+(?:\.[0-9]+)?)\s*Gb/s"
        ),
        connected_port=matched_number(settings.get("Connected Port Number"), r"(\d+)"),
        media_errors=number(state.get("Media Error Count")),
        other_errors=number(state.get("Other Error Count")),
        predictive_errors=number(state.get("Predictive Failure Count")),
        smart_alerted=smart_alerted,
    )


class HbaMetrics:
    def __init__(self) -> None:
        self.registry = CollectorRegistry()
        self.collect_success = self.gauge(
            "collect_success",
            "Whether the last HBA metrics collection succeeded.",
            ("controller",),
        )
        self.info = self.gauge(
            "info",
            "Static Broadcom HBA metadata.",
            (
                "adapter_type",
                "controller",
                "driver",
                "firmware_version",
                "model",
                "serial",
                "status",
            ),
        )
        self.temperature = self.gauge(
            "temperature_celsius",
            "HBA temperature in degrees Celsius.",
            ("controller", "sensor"),
        )
        self.healthy = self.controller_gauge("healthy", "Whether the HBA controller is healthy.")
        self.degraded = self.controller_gauge(
            "degraded",
            "Whether the HBA controller reports a degraded state.",
        )
        self.failed = self.controller_gauge(
            "failed",
            "Whether the HBA controller reports a failed state.",
        )
        self.correctable = self.controller_gauge(
            "memory_correctable_errors",
            "Correctable HBA memory errors reported by StorCLI.",
        )
        self.uncorrectable = self.controller_gauge(
            "memory_uncorrectable_errors",
            "Uncorrectable HBA memory errors reported by StorCLI.",
        )
        self.backend_ports = self.controller_gauge(
            "backend_ports",
            "Backend port count reported by StorCLI.",
        )
        self.physical_drives = self.controller_gauge(
            "physical_drives",
            "Visible physical drives reported by StorCLI.",
        )
        self.drive_visible = self.drive_gauge(
            "drive_visible",
            "Whether the expected drive is visible to the HBA.",
        )
        self.drive_info = self.gauge(
            "drive_info",
            "Visible drive metadata reported by StorCLI.",
            (*DRIVE_LABELS, "disk_id", "firmware", "interface", "media", "state"),
        )
        self.drive_link_speed = self.drive_gauge(
            "drive_link_speed_gbps",
            "Visible drive link speed in Gbps.",
        )
        self.drive_connected_port = self.drive_gauge(
            "drive_connected_port",
            "Connected HBA backend port number for a visible drive.",
        )
        self.drive_media_errors = self.drive_gauge(
            "drive_media_errors",
            "Visible drive media errors reported by StorCLI.",
        )
        self.drive_other_errors = self.drive_gauge(
            "drive_other_errors",
            "Visible drive other errors reported by StorCLI.",
        )
        self.drive_predictive_errors = self.drive_gauge(
            "drive_predictive_errors",
            "Visible drive predictive failure errors reported by StorCLI.",
        )
        self.drive_smart_alerted = self.drive_gauge(
            "drive_smart_alerted",
            "Whether StorCLI reports SMART alert status for the drive.",
        )

    def gauge(self, suffix: str, documentation: str, labels: tuple[str, ...]) -> Gauge:
        return Gauge(PREFIX + suffix, documentation, labels, registry=self.registry)

    def controller_gauge(self, suffix: str, documentation: str) -> Gauge:
        return self.gauge(suffix, documentation, ("controller",))

    def drive_gauge(self, suffix: str, documentation: str) -> Gauge:
        return self.gauge(suffix, documentation, DRIVE_LABELS)

    @staticmethod
    def set_optional(metric: Gauge, labels: tuple[str, ...], value: float | None) -> None:
        if value is not None:
            metric.labels(*labels).set(value)

    def collect(self, document: StorcliDocument, bay_mappings: dict[str, BayMapping]) -> None:
        visible_by_serial: set[str] = set()
        successful_controllers: set[str] = set()
        for controller in document.controllers:
            controller_id = clean(controller.command.controller)
            if controller.command.status.strip() != "Success":
                self.collect_success.labels(controller_id).set(0)
                continue

            response = controller.response
            controller_id = clean(response.basics.controller)
            status = response.status.controller_status.strip()
            successful_controllers.add(controller_id)
            self.collect_success.labels(controller_id).set(1)
            self.info.labels(
                response.basics.adapter_type.strip(),
                controller_id,
                response.version.driver.strip(),
                response.version.firmware.strip(),
                response.basics.model.strip(),
                response.basics.serial.strip(),
                status,
            ).set(1)
            temperature = number(
                response.hardware.temperature_celsius
                if response.hardware.temperature_celsius is not None
                else response.hardware.temperature_celcius
            )
            self.set_optional(self.temperature, (controller_id, "roc"), temperature)
            self.healthy.labels(controller_id).set(1 if status in {"OK", "Optimal"} else 0)
            self.degraded.labels(controller_id).set(1 if status == "Degraded" else 0)
            self.failed.labels(controller_id).set(1 if status == "Failed" else 0)
            self.set_optional(
                self.correctable,
                (controller_id,),
                number(response.status.correctable_errors),
            )
            self.set_optional(
                self.uncorrectable,
                (controller_id,),
                number(response.status.uncorrectable_errors),
            )
            self.set_optional(
                self.backend_ports,
                (controller_id,),
                number(response.hardware.backend_ports),
            )

            drives = [
                drive
                for name, value in response.physical_devices.items()
                if not name.endswith(" - Detailed Information")
                if (
                    drive := visible_drive(
                        controller_id, value, response.physical_devices, bay_mappings
                    )
                )
                is not None
            ]
            self.physical_drives.labels(controller_id).set(len(drives))
            for drive in drives:
                if drive.serial:
                    visible_by_serial.add(drive.serial)
                labels = drive.common_labels()
                self.drive_visible.labels(*labels).set(1)
                self.drive_info.labels(
                    *labels,
                    drive.disk_id,
                    drive.firmware,
                    drive.interface,
                    drive.media,
                    drive.state,
                ).set(1)
                self.set_optional(self.drive_link_speed, labels, drive.link_speed_gbps)
                self.set_optional(self.drive_connected_port, labels, drive.connected_port)
                self.set_optional(self.drive_media_errors, labels, drive.media_errors)
                self.set_optional(self.drive_other_errors, labels, drive.other_errors)
                self.set_optional(self.drive_predictive_errors, labels, drive.predictive_errors)
                self.set_optional(self.drive_smart_alerted, labels, drive.smart_alerted)

        if not successful_controllers:
            self.collect_success.labels("all").set(0)
        for serial, mapping in bay_mappings.items():
            if serial not in visible_by_serial:
                self.drive_visible.labels(
                    clean(mapping.bay),
                    clean(mapping.col),
                    clean(mapping.row),
                    "",
                    "",
                    "",
                    mapping.model.strip(),
                    serial,
                ).set(0)


@dataclass(frozen=True)
class HbaExporter:
    source: StorcliSource

    def run(self, bay_map_path: Path, output_path: Path) -> None:
        metrics = HbaMetrics()
        error: OSError | UnicodeError | HbaError | ValidationError | None = None
        try:
            bay_mappings = BayMappings.model_validate_json(
                bay_map_path.read_text(encoding="utf-8")
            ).by_serial()
            metrics.collect(self.source.collect(), bay_mappings)
        except (OSError, UnicodeError, HbaError, ValidationError) as caught:
            error = caught
            metrics.collect_success.labels("all").set(0)
        write_text_atomic(
            output_path,
            generate_latest(metrics.registry).decode("utf-8"),
            mode=0o644,
        )
        if error is not None:
            raise HbaError(str(error)) from error
