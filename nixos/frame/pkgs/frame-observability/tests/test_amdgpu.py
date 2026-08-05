from __future__ import annotations

import json
from collections.abc import Iterator

import pytest
from prometheus_client import CollectorRegistry
from prometheus_client.parser import text_string_to_metric_families
from pydantic import ValidationError

from frame_observability.amdgpu import (
    AmdgpuSample,
    Arguments,
    Reading,
    collect,
    gpu_metrics_power,
    gpu_metrics_temperature,
    parse_arguments,
    parse_samples,
    scaled_value,
    success_registry,
)
from frame_observability.textfile import render


class StaticSource:
    def __init__(self, sample: AmdgpuSample | None = None, error: OSError | None = None) -> None:
        self.result = sample
        self.error = error
        self.calls: list[tuple[int, float]] = []

    def sample(self, interval_ms: int, timeout: float) -> AmdgpuSample:
        self.calls.append((interval_ms, timeout))
        if self.error is not None:
            raise self.error
        assert self.result is not None
        return self.result


def clock(values: Iterator[float]) -> float:
    return next(values)


def samples(registry: CollectorRegistry) -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    result: dict[tuple[str, tuple[tuple[str, str], ...]], float] = {}
    for family in text_string_to_metric_families(render(registry).decode()):
        for sample in family.samples:
            result[(sample.name, tuple(sorted(sample.labels.items())))] = sample.value
    return result


def device_labels(**extra: str) -> tuple[tuple[str, str], ...]:
    return tuple(
        sorted(
            {
                "device": "Radeon RX",
                "gpu": "0",
                "pci": "0000:0c:00.0",
                **extra,
            }.items()
        )
    )


def fixture() -> dict[str, object]:
    return {
        "ROCm version": "6.4",
        "amdgpu_top_version": {"major": 0, "minor": 11, "patch": 0},
        "devices": [
            {
                "Info": {
                    "PCI": "0000:0c:00.0",
                    "DeviceName": "Radeon RX",
                    "ASIC Name": "NAVI",
                    "Chip Class": "GFX11",
                },
                "gpu_activity": {"GFX": {"value": 45, "unit": "%"}},
                "VRAM": {
                    "Total VRAM": {"value": 16, "unit": "MiB"},
                    "Total VRAM Usage": {"value": 4, "unit": "MiB"},
                    "Total GTT": 8,
                    "Total GTT Usage": 2,
                },
                "Sensors": {
                    "Edge Temperature": {"value": 50, "unit": "C"},
                    "Edge Critical Temperature": 95,
                    "Junction Emergency Temperature": 110,
                    "GFX Power": 42,
                    "GFX_SCLK": {"value": 2, "unit": "MHz"},
                    "VDDGFX": {"value": 950, "unit": "mV"},
                    "Fan": 1200,
                },
                "gpu_metrics": {
                    "header": {"format_revision": 2},
                    "temperature_hotspot": 5500,
                    "average_socket_power": 42000,
                    "current_gfxclk": 2200,
                    "pcie_frequency": 16,
                },
            }
        ],
    }


def test_ndjson_parser_validates_samples_and_returns_the_last() -> None:
    first = {"ROCm version": "old", "devices": []}
    output = f"{json.dumps(first)}\n\n{json.dumps(fixture())}\n"

    sample = parse_samples(output)

    assert sample.rocm_version == "6.4"
    assert sample.amdgpu_top_version.label == "0.11.0"
    assert sample.devices[0].info.device_name == "Radeon RX"


def test_ndjson_parser_rejects_empty_and_invalid_samples() -> None:
    with pytest.raises(ValueError, match="no JSON samples"):
        parse_samples("\n")
    with pytest.raises(ValidationError):
        parse_samples('{"devices": [{"Sensors": {"Fan": {"unit": "rpm"}}}]}')


def test_unit_scaling_and_gpu_metrics_revisions() -> None:
    assert scaled_value(Reading(value=2, unit="MiB"), "bytes") == 2 * 1024 * 1024
    assert scaled_value(Reading(value=2, unit="MHz"), "hertz") == 2_000_000
    assert scaled_value(Reading(value=950, unit="mV"), "volts") == 0.95
    assert scaled_value(4, "bytes") == 4
    assert scaled_value(None, "bytes") is None
    assert gpu_metrics_temperature(5500) == 55
    assert gpu_metrics_temperature(0) is None
    assert gpu_metrics_power(42000, 2) == 42
    assert gpu_metrics_power(42, 1) == 42


def test_success_registry_preserves_device_sensor_and_firmware_metrics() -> None:
    registry = success_registry(AmdgpuSample.model_validate(fixture()), 0.25)

    values = samples(registry)
    assert values[("host_observability_amdgpu_collector_ok", ())] == 1
    assert values[("host_observability_amdgpu_devices", ())] == 1
    assert values[("host_observability_amdgpu_activity_percent", device_labels(engine="GFX"))] == 45
    assert (
        values[
            ("host_observability_amdgpu_memory_bytes", device_labels(state="total", type="vram"))
        ]
        == 16 * 1024 * 1024
    )
    assert (
        values[("host_observability_amdgpu_temperature_celsius", device_labels(sensor="Edge"))]
        == 50
    )
    assert (
        values[
            (
                "host_observability_amdgpu_temperature_limit_celsius",
                device_labels(limit="critical", sensor="Edge"),
            )
        ]
        == 95
    )
    assert (
        values[("host_observability_amdgpu_power_watts", device_labels(sensor="GFX Power"))] == 42
    )
    assert (
        values[("host_observability_amdgpu_clock_hertz", device_labels(clock="GFX_SCLK"))]
        == 2_000_000
    )
    assert values[("host_observability_amdgpu_voltage_volts", device_labels(rail="VDDGFX"))] == 0.95
    assert values[("host_observability_amdgpu_fan_rpm", device_labels(sensor="Fan"))] == 1200
    assert (
        values[
            (
                "host_observability_amdgpu_temperature_celsius",
                device_labels(sensor="temperature_hotspot"),
            )
        ]
        == 55
    )
    assert (
        values[
            (
                "host_observability_amdgpu_power_watts",
                device_labels(sensor="average_socket_power"),
            )
        ]
        == 42
    )


def test_collection_failure_emits_health_metrics_and_preserves_source_options() -> None:
    source = StaticSource(error=OSError("device unavailable"))
    times = iter([4.0, 4.5])

    registry = collect(source, 250, 3.5, lambda: clock(times))

    assert source.calls == [(250, 3.5)]
    values = samples(registry)
    assert values[("host_observability_amdgpu_collector_ok", ())] == 0
    assert values[("host_observability_amdgpu_collector_duration_seconds", ())] == 0.5


def test_cli_uses_wrapped_executable_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FRAME_AMDGPU_TOP", "/nix/store/amdgpu_top")

    arguments = parse_arguments([])

    assert arguments == Arguments("/nix/store/amdgpu_top", "-", 1000, 10)
