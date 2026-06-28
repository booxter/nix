import argparse
import json
import math
import os
import subprocess
import tempfile
import time


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class PrometheusText:
    def __init__(self):
        self.lines = []
        self.declared = set()

    def metric(self, name, help_text, metric_type, value, labels=None):
        if value is None:
            return
        if isinstance(value, float) and not math.isfinite(value):
            return
        if name not in self.declared:
            self.lines.append(f"# HELP {name} {help_text}")
            self.lines.append(f"# TYPE {name} {metric_type}")
            self.declared.add(name)
        label_text = ""
        if labels:
            pairs = [f'{key}="{prom_escape(val)}"' for key, val in labels.items()]
            label_text = "{" + ",".join(pairs) + "}"
        self.lines.append(f"{name}{label_text} {value}")

    def render(self):
        return "\n".join(self.lines) + "\n"


def value_unit(node):
    if isinstance(node, dict) and "value" in node:
        return node["value"], node.get("unit")
    if isinstance(node, (int, float)):
        return node, None
    return None, None


def scaled_value(node, expected_unit):
    value, unit = value_unit(node)
    if value is None:
        return None
    if expected_unit == "bytes":
        if unit == "MiB":
            return float(value) * 1024 * 1024
        if unit in (None, "B"):
            return value
    if expected_unit == "hertz":
        if unit == "MHz":
            return float(value) * 1000 * 1000
        if unit in (None, "Hz"):
            return value
    if expected_unit == "volts":
        if unit == "mV":
            return float(value) / 1000
        if unit in (None, "V"):
            return value
    return value


def gpu_metrics_format_revision(gpu_metrics):
    header = gpu_metrics.get("header") if isinstance(gpu_metrics, dict) else None
    if not isinstance(header, dict):
        return None
    return header.get("format_revision")


def gpu_metrics_temperature_celsius(value):
    if not isinstance(value, (int, float)) or value <= 0:
        return None
    if value >= 1000:
        return float(value) / 100
    return value


def gpu_metrics_power_watts(value, format_revision):
    if not isinstance(value, (int, float)):
        return None
    if format_revision is not None and format_revision >= 2:
        return float(value) / 1000
    return value


def parse_amdgpu_top_json(stdout):
    samples = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        samples.append(json.loads(line))
    if not samples:
        raise ValueError("amdgpu_top produced no JSON samples")
    return samples[-1]


def run_amdgpu_top(amdgpu_top, sample_interval_ms, timeout):
    result = subprocess.run(
        [
            amdgpu_top,
            "--json",
            "-n",
            "1",
            "-s",
            str(sample_interval_ms),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return parse_amdgpu_top_json(result.stdout)


def version_label(version):
    if not isinstance(version, dict):
        return ""
    parts = [version.get(key) for key in ("major", "minor", "patch")]
    if any(part is None for part in parts):
        return ""
    return ".".join(str(part) for part in parts)


def device_labels(device, index):
    info = device.get("Info") or {}
    path = info.get("DevicePath") or {}
    pci = info.get("PCI") or path.get("pci") or f"gpu{index}"
    return {
        "gpu": str(index),
        "pci": pci,
        "device": info.get("DeviceName") or path.get("DeviceName") or "unknown",
    }


def collect_metrics(data, duration):
    out = PrometheusText()
    base_labels = {
        "rocm_version": data.get("ROCm version") or "",
        "amdgpu_top_version": version_label(data.get("amdgpu_top_version")),
    }
    devices = data.get("devices") or []

    out.metric(
        "host_observability_amdgpu_collector_ok",
        "Whether the latest AMD GPU metrics collection iteration succeeded.",
        "gauge",
        1,
    )
    out.metric(
        "host_observability_amdgpu_collector_duration_seconds",
        "Wall-clock duration of the latest AMD GPU metrics collection iteration.",
        "gauge",
        duration,
    )
    out.metric(
        "host_observability_amdgpu_devices",
        "Number of AMD GPU devices returned by amdgpu_top.",
        "gauge",
        len(devices),
    )

    for index, device in enumerate(devices):
        labels = device_labels(device, index)
        info = device.get("Info") or {}
        info_labels = {
            **labels,
            **base_labels,
            "asic": info.get("ASIC Name") or "",
            "chip_class": info.get("Chip Class") or "",
        }
        out.metric(
            "host_observability_amdgpu_info",
            "Static AMD GPU device information.",
            "gauge",
            1,
            info_labels,
        )

        for engine, node in (device.get("gpu_activity") or {}).items():
            out.metric(
                "host_observability_amdgpu_activity_percent",
                "AMDGPU activity percentage by engine.",
                "gauge",
                scaled_value(node, "percent"),
                {**labels, "engine": engine},
            )

        vram = device.get("VRAM") or {}
        memory_fields = {
            "Total VRAM": ("vram", "total"),
            "Total VRAM Usage": ("vram", "used"),
            "Total GTT": ("gtt", "total"),
            "Total GTT Usage": ("gtt", "used"),
        }
        for key, (memory_type, state) in memory_fields.items():
            out.metric(
                "host_observability_amdgpu_memory_bytes",
                "AMDGPU memory size by type and state.",
                "gauge",
                scaled_value(vram.get(key), "bytes"),
                {**labels, "type": memory_type, "state": state},
            )

        sensors = device.get("Sensors") or {}
        for sensor, node in sensors.items():
            if (
                sensor.endswith(" Temperature")
                and " Critical " not in sensor
                and " Emergency " not in sensor
            ):
                out.metric(
                    "host_observability_amdgpu_temperature_celsius",
                    "AMDGPU current temperature by sensor.",
                    "gauge",
                    scaled_value(node, "celsius"),
                    {**labels, "sensor": sensor.removesuffix(" Temperature")},
                )
            elif sensor.endswith(" Critical Temperature") or sensor.endswith(
                " Emergency Temperature"
            ):
                limit = "critical" if " Critical " in sensor else "emergency"
                sensor_name = sensor.replace(" Critical Temperature", "").replace(
                    " Emergency Temperature", ""
                )
                out.metric(
                    "host_observability_amdgpu_temperature_limit_celsius",
                    "AMDGPU temperature limit by sensor.",
                    "gauge",
                    scaled_value(node, "celsius"),
                    {**labels, "sensor": sensor_name, "limit": limit},
                )
            elif sensor in ("GFX Power", "Average Power", "Input Power"):
                out.metric(
                    "host_observability_amdgpu_power_watts",
                    "AMDGPU power sensor reading.",
                    "gauge",
                    scaled_value(node, "watts"),
                    {**labels, "sensor": sensor},
                )
            elif sensor in ("GFX_SCLK", "GFX_MCLK", "FCLK"):
                out.metric(
                    "host_observability_amdgpu_clock_hertz",
                    "AMDGPU clock frequency by source.",
                    "gauge",
                    scaled_value(node, "hertz"),
                    {**labels, "clock": sensor},
                )
            elif sensor in ("VDDNB", "VDDGFX"):
                out.metric(
                    "host_observability_amdgpu_voltage_volts",
                    "AMDGPU voltage sensor reading.",
                    "gauge",
                    scaled_value(node, "volts"),
                    {**labels, "rail": sensor},
                )
            elif sensor in ("Fan", "Fan Max"):
                out.metric(
                    "host_observability_amdgpu_fan_rpm",
                    "AMDGPU fan speed reading.",
                    "gauge",
                    scaled_value(node, "rpm"),
                    {**labels, "sensor": sensor},
                )

        gpu_metrics = device.get("gpu_metrics") or {}
        gpu_metrics_revision = gpu_metrics_format_revision(gpu_metrics)
        for name, value in gpu_metrics.items():
            if name.startswith("temperature_") and isinstance(value, (int, float)):
                out.metric(
                    "host_observability_amdgpu_temperature_celsius",
                    "AMDGPU current temperature by sensor.",
                    "gauge",
                    gpu_metrics_temperature_celsius(value),
                    {**labels, "sensor": name},
                )
            elif name.endswith("_power") and isinstance(value, (int, float)):
                out.metric(
                    "host_observability_amdgpu_power_watts",
                    "AMDGPU power sensor reading.",
                    "gauge",
                    gpu_metrics_power_watts(value, gpu_metrics_revision),
                    {**labels, "sensor": name},
                )
            elif (
                "_frequency" in name
                or name.startswith("current_")
                and name.endswith("clk")
            ) and isinstance(value, (int, float)):
                out.metric(
                    "host_observability_amdgpu_clock_hertz",
                    "AMDGPU clock frequency by source.",
                    "gauge",
                    float(value) * 1000 * 1000,
                    {**labels, "clock": name},
                )

    return out.render()


def failure_metrics(duration):
    out = PrometheusText()
    out.metric(
        "host_observability_amdgpu_collector_ok",
        "Whether the latest AMD GPU metrics collection iteration succeeded.",
        "gauge",
        0,
    )
    out.metric(
        "host_observability_amdgpu_collector_duration_seconds",
        "Wall-clock duration of the latest AMD GPU metrics collection iteration.",
        "gauge",
        duration,
    )
    return out.render()


def write_output(path, content):
    if path == "-":
        print(content, end="")
        return
    directory = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.", dir=directory, text=True
    )
    try:
        with os.fdopen(fd, "w") as tmp:
            tmp.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--amdgpu-top", default="amdgpu_top")
    parser.add_argument("--output", default="-")
    parser.add_argument("--sample-interval-ms", type=int, default=1000)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()

    start = time.monotonic()
    try:
        data = run_amdgpu_top(args.amdgpu_top, args.sample_interval_ms, args.timeout)
        content = collect_metrics(data, time.monotonic() - start)
    except Exception:
        content = failure_metrics(time.monotonic() - start)
    write_output(args.output, content)


if __name__ == "__main__":
    main()
