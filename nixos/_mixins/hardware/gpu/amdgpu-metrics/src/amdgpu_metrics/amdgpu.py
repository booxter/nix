from __future__ import annotations

import argparse
import os
import subprocess
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol, overload

from prometheus_client import CollectorRegistry, Gauge
from pydantic import BaseModel, ConfigDict, Field, JsonValue, ValidationError

from .textfile import write


class ToolVersion(BaseModel):
    model_config = ConfigDict(extra="ignore")

    major: int | None = None
    minor: int | None = None
    patch: int | None = None

    @property
    def label(self) -> str:
        parts = (self.major, self.minor, self.patch)
        return "" if any(part is None for part in parts) else ".".join(str(part) for part in parts)


class Reading(BaseModel):
    model_config = ConfigDict(extra="ignore")

    value: float
    unit: str | None = None


ReadingValue = Reading | float


class DevicePath(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    device_name: str | None = Field(default=None, alias="DeviceName")
    pci: str | None = None


class DeviceInfo(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    asic_name: str = Field(default="", alias="ASIC Name")
    chip_class: str = Field(default="", alias="Chip Class")
    device_name: str | None = Field(default=None, alias="DeviceName")
    device_path: DevicePath = Field(default_factory=DevicePath, alias="DevicePath")
    pci: str | None = Field(default=None, alias="PCI")


class Device(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    gpu_activity: dict[str, JsonValue] = Field(default_factory=dict)
    gpu_metrics: dict[str, JsonValue] = Field(default_factory=dict)
    info: DeviceInfo = Field(default_factory=DeviceInfo, alias="Info")
    sensors: dict[str, JsonValue] = Field(default_factory=dict, alias="Sensors")
    vram: dict[str, JsonValue] = Field(default_factory=dict, alias="VRAM")


class AmdgpuSample(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    amdgpu_top_version: ToolVersion = Field(default_factory=ToolVersion)
    devices: list[Device] = Field(default_factory=list)
    rocm_version: str | None = Field(default=None, alias="ROCm version")


class SampleSource(Protocol):
    def sample(self, interval_ms: int, timeout: float) -> AmdgpuSample: ...


@dataclass(frozen=True)
class CommandSource:
    executable: str

    def sample(self, interval_ms: int, timeout: float) -> AmdgpuSample:
        # amdgpu_top owns kernel/device decoding and has no supported Python
        # binding. Keep its JSON mode as one exact, typed process boundary.
        result = subprocess.run(
            [self.executable, "--json", "-n", "1", "-s", str(interval_ms)],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return parse_samples(result.stdout)


def parse_samples(output: str) -> AmdgpuSample:
    samples = [
        AmdgpuSample.model_validate_json(line)
        for raw_line in output.splitlines()
        if (line := raw_line.strip())
    ]
    if not samples:
        raise ValueError("amdgpu_top produced no JSON samples")
    return samples[-1]


@overload
def scaled_value(value: None, expected_unit: str) -> None: ...


@overload
def scaled_value(value: ReadingValue, expected_unit: str) -> float: ...


def scaled_value(value: ReadingValue | None, expected_unit: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, Reading):
        number = value.value
        unit = value.unit
    else:
        number = value
        unit = None
    if expected_unit == "bytes" and unit == "MiB":
        return number * 1024 * 1024
    if expected_unit == "hertz" and unit == "MHz":
        return number * 1000 * 1000
    if expected_unit == "volts" and unit == "mV":
        return number / 1000
    return number


def scaled_json_value(value: JsonValue, expected_unit: str) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        return scaled_value(value, expected_unit)
    if isinstance(value, dict):
        try:
            return scaled_value(Reading.model_validate(value), expected_unit)
        except ValidationError:
            return None
    return None


def gpu_metrics_revision(metrics: Mapping[str, JsonValue]) -> float | None:
    header = metrics.get("header")
    if not isinstance(header, dict):
        return None
    revision = header.get("format_revision")
    return float(revision) if isinstance(revision, int | float) else None


def gpu_metrics_temperature(value: int | float) -> float | None:
    if value <= 0:
        return None
    return float(value) / 100 if value >= 1000 else float(value)


def gpu_metrics_power(value: int | float, revision: float | None) -> float:
    return float(value) / 1000 if revision is not None and revision >= 2 else float(value)


def _gauge(
    registry: CollectorRegistry,
    name: str,
    documentation: str,
    labels: Sequence[str] = (),
) -> Gauge:
    return Gauge(name, documentation, labelnames=labels, registry=registry)


def _device_labels(device: Device, index: int) -> tuple[str, str, str]:
    pci = device.info.pci or device.info.device_path.pci or f"gpu{index}"
    name = device.info.device_name or device.info.device_path.device_name or "unknown"
    return str(index), pci, name


@dataclass(frozen=True)
class DeviceGauges:
    info: Gauge
    activity: Gauge
    memory: Gauge
    temperature: Gauge
    temperature_limit: Gauge
    power: Gauge
    clock: Gauge
    voltage: Gauge
    fan: Gauge


def _device_gauges(registry: CollectorRegistry) -> DeviceGauges:
    return DeviceGauges(
        info=_gauge(
            registry,
            "host_observability_amdgpu_info",
            "Static AMD GPU device information.",
            ("gpu", "pci", "device", "rocm_version", "amdgpu_top_version", "asic", "chip_class"),
        ),
        activity=_gauge(
            registry,
            "host_observability_amdgpu_activity_percent",
            "AMDGPU activity percentage by engine.",
            ("gpu", "pci", "device", "engine"),
        ),
        memory=_gauge(
            registry,
            "host_observability_amdgpu_memory_bytes",
            "AMDGPU memory size by type and state.",
            ("gpu", "pci", "device", "type", "state"),
        ),
        temperature=_gauge(
            registry,
            "host_observability_amdgpu_temperature_celsius",
            "AMDGPU current temperature by sensor.",
            ("gpu", "pci", "device", "sensor"),
        ),
        temperature_limit=_gauge(
            registry,
            "host_observability_amdgpu_temperature_limit_celsius",
            "AMDGPU temperature limit by sensor.",
            ("gpu", "pci", "device", "sensor", "limit"),
        ),
        power=_gauge(
            registry,
            "host_observability_amdgpu_power_watts",
            "AMDGPU power sensor reading.",
            ("gpu", "pci", "device", "sensor"),
        ),
        clock=_gauge(
            registry,
            "host_observability_amdgpu_clock_hertz",
            "AMDGPU clock frequency by source.",
            ("gpu", "pci", "device", "clock"),
        ),
        voltage=_gauge(
            registry,
            "host_observability_amdgpu_voltage_volts",
            "AMDGPU voltage sensor reading.",
            ("gpu", "pci", "device", "rail"),
        ),
        fan=_gauge(
            registry,
            "host_observability_amdgpu_fan_rpm",
            "AMDGPU fan speed reading.",
            ("gpu", "pci", "device", "sensor"),
        ),
    )


def _record_memory(gauges: DeviceGauges, labels: tuple[str, str, str], device: Device) -> None:
    memory_fields = {
        "Total VRAM": ("vram", "total"),
        "Total VRAM Usage": ("vram", "used"),
        "Total GTT": ("gtt", "total"),
        "Total GTT Usage": ("gtt", "used"),
    }
    for key, (memory_type, state) in memory_fields.items():
        scaled = scaled_json_value(device.vram.get(key), "bytes")
        if scaled is not None:
            gauges.memory.labels(*labels, memory_type, state).set(scaled)


def _record_sensors(gauges: DeviceGauges, labels: tuple[str, str, str], device: Device) -> None:
    for sensor, reading in device.sensors.items():
        scaled = scaled_json_value(reading, "celsius")
        if scaled is None:
            continue
        if (
            sensor.endswith(" Temperature")
            and " Critical " not in sensor
            and " Emergency " not in sensor
        ):
            gauges.temperature.labels(*labels, sensor.removesuffix(" Temperature")).set(scaled)
        elif sensor.endswith((" Critical Temperature", " Emergency Temperature")):
            limit = "critical" if " Critical " in sensor else "emergency"
            sensor_name = sensor.replace(" Critical Temperature", "").replace(
                " Emergency Temperature", ""
            )
            gauges.temperature_limit.labels(*labels, sensor_name, limit).set(scaled)
        elif sensor in ("GFX Power", "Average Power", "Input Power"):
            if (scaled := scaled_json_value(reading, "watts")) is not None:
                gauges.power.labels(*labels, sensor).set(scaled)
        elif sensor in ("GFX_SCLK", "GFX_MCLK", "FCLK"):
            if (scaled := scaled_json_value(reading, "hertz")) is not None:
                gauges.clock.labels(*labels, sensor).set(scaled)
        elif sensor in ("VDDNB", "VDDGFX"):
            if (scaled := scaled_json_value(reading, "volts")) is not None:
                gauges.voltage.labels(*labels, sensor).set(scaled)
        elif (
            sensor in ("Fan", "Fan Max")
            and (scaled := scaled_json_value(reading, "rpm")) is not None
        ):
            gauges.fan.labels(*labels, sensor).set(scaled)


def _record_gpu_metrics(
    gauges: DeviceGauges,
    labels: tuple[str, str, str],
    device: Device,
) -> None:
    revision = gpu_metrics_revision(device.gpu_metrics)
    for name, metric_value in device.gpu_metrics.items():
        if isinstance(metric_value, bool) or not isinstance(metric_value, int | float):
            continue
        if name.startswith("temperature_"):
            if (converted := gpu_metrics_temperature(metric_value)) is not None:
                gauges.temperature.labels(*labels, name).set(converted)
        elif name.endswith("_power"):
            gauges.power.labels(*labels, name).set(gpu_metrics_power(metric_value, revision))
        elif "_frequency" in name or (name.startswith("current_") and name.endswith("clk")):
            gauges.clock.labels(*labels, name).set(float(metric_value) * 1000 * 1000)


def _record_device(
    gauges: DeviceGauges,
    base_labels: tuple[str, str],
    device: Device,
    index: int,
) -> None:
    labels = _device_labels(device, index)
    gauges.info.labels(
        *labels,
        *base_labels,
        device.info.asic_name,
        device.info.chip_class,
    ).set(1)
    for engine, reading in device.gpu_activity.items():
        if (scaled := scaled_json_value(reading, "percent")) is not None:
            gauges.activity.labels(*labels, engine).set(scaled)
    _record_memory(gauges, labels, device)
    _record_sensors(gauges, labels, device)
    _record_gpu_metrics(gauges, labels, device)


def success_registry(sample: AmdgpuSample, duration: float) -> CollectorRegistry:
    registry = CollectorRegistry()
    _gauge(
        registry,
        "host_observability_amdgpu_collector_ok",
        "Whether the latest AMD GPU metrics collection iteration succeeded.",
    ).set(1)
    _gauge(
        registry,
        "host_observability_amdgpu_collector_duration_seconds",
        "Wall-clock duration of the latest AMD GPU metrics collection iteration.",
    ).set(duration)
    _gauge(
        registry,
        "host_observability_amdgpu_devices",
        "Number of AMD GPU devices returned by amdgpu_top.",
    ).set(len(sample.devices))

    base_labels = (sample.rocm_version or "", sample.amdgpu_top_version.label)
    gauges = _device_gauges(registry)
    for index, device in enumerate(sample.devices):
        _record_device(gauges, base_labels, device, index)
    return registry


def failure_registry(duration: float) -> CollectorRegistry:
    registry = CollectorRegistry()
    _gauge(
        registry,
        "host_observability_amdgpu_collector_ok",
        "Whether the latest AMD GPU metrics collection iteration succeeded.",
    ).set(0)
    _gauge(
        registry,
        "host_observability_amdgpu_collector_duration_seconds",
        "Wall-clock duration of the latest AMD GPU metrics collection iteration.",
    ).set(duration)
    return registry


def collect(
    source: SampleSource,
    interval_ms: int,
    timeout: float,
    clock: Callable[[], float] = time.monotonic,
) -> CollectorRegistry:
    started = clock()
    try:
        sample = source.sample(interval_ms, timeout)
    except (OSError, subprocess.SubprocessError, ValidationError, ValueError):
        return failure_registry(clock() - started)
    return success_registry(sample, clock() - started)


@dataclass(frozen=True)
class Arguments:
    amdgpu_top: str
    output: str
    sample_interval_ms: int
    timeout: float


def parse_arguments(argv: Sequence[str] | None = None) -> Arguments:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--amdgpu-top", default=os.environ.get("AMDGPU_METRICS_AMDGPU_TOP", "amdgpu_top")
    )
    parser.add_argument("--output", default="-")
    parser.add_argument("--sample-interval-ms", type=int, default=1000)
    parser.add_argument("--timeout", type=float, default=10)
    parsed = parser.parse_args(argv)
    return Arguments(parsed.amdgpu_top, parsed.output, parsed.sample_interval_ms, parsed.timeout)


def main(argv: Sequence[str] | None = None) -> None:
    arguments = parse_arguments(argv)
    registry = collect(
        CommandSource(arguments.amdgpu_top),
        arguments.sample_interval_ms,
        arguments.timeout,
    )
    write(registry, arguments.output)
