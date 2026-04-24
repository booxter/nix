#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


HELP_LINES = [
    (
        "host_observability_hba_collect_success",
        "Whether the last HBA metrics collection succeeded.",
        "gauge",
    ),
    (
        "host_observability_hba_info",
        "Static Broadcom HBA metadata.",
        "gauge",
    ),
    (
        "host_observability_hba_temperature_celsius",
        "HBA temperature in degrees Celsius.",
        "gauge",
    ),
    (
        "host_observability_hba_healthy",
        "Whether the HBA controller is healthy.",
        "gauge",
    ),
    (
        "host_observability_hba_degraded",
        "Whether the HBA controller reports a degraded state.",
        "gauge",
    ),
    (
        "host_observability_hba_failed",
        "Whether the HBA controller reports a failed state.",
        "gauge",
    ),
    (
        "host_observability_hba_memory_correctable_errors",
        "Correctable HBA memory errors reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_memory_uncorrectable_errors",
        "Uncorrectable HBA memory errors reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_backend_ports",
        "Backend port count reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_physical_drives",
        "Visible physical drives reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_visible",
        "Whether the expected drive is visible to the HBA.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_info",
        "Visible drive metadata reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_link_speed_gbps",
        "Visible drive link speed in Gbps.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_connected_port",
        "Connected HBA backend port number for a visible drive.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_media_errors",
        "Visible drive media errors reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_other_errors",
        "Visible drive other errors reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_predictive_errors",
        "Visible drive predictive failure errors reported by StorCLI.",
        "gauge",
    ),
    (
        "host_observability_hba_drive_smart_alerted",
        "Whether StorCLI reports SMART alert status for the drive.",
        "gauge",
    ),
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Export Broadcom StorCLI controller and drive metrics for node_exporter textfile collector."
    )
    parser.add_argument("--storcli-path", required=True)
    parser.add_argument("--bay-map", required=True)
    parser.add_argument("--output-file", required=True)
    parser.add_argument(
        "--input-json",
        help="Read StorCLI JSON from this file instead of invoking storcli. Use '-' for stdin.",
    )
    return parser.parse_args()


def metric_headers():
    lines = []
    for name, help_text, metric_type in HELP_LINES:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {metric_type}")
    return lines


def clean(value):
    if value is None:
        return ""
    return str(value).strip()


def parse_number(value):
    if value is None:
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


def parse_speed_gbps(value):
    text = clean(value)
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*Gb/s", text)
    if not match:
        return None
    return float(match.group(1))


def parse_connected_port(value):
    text = clean(value)
    match = re.search(r"(\d+)", text)
    if not match:
        return None
    return float(match.group(1))


def escape_label(value):
    return clean(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def emit_metric(lines, name, value, labels=None):
    if value is None:
        return
    if labels:
        label_pairs = ",".join(
            f'{key}="{escape_label(labels[key])}"' for key in sorted(labels.keys())
        )
        lines.append(f"{name}{{{label_pairs}}} {value}")
    else:
        lines.append(f"{name} {value}")


def load_storcli_json(args):
    if args.input_json:
        if args.input_json == "-":
            return json.load(sys.stdin)
        with open(args.input_json, "r", encoding="utf-8") as handle:
            return json.load(handle)

    proc = subprocess.run(
        [args.storcli_path, "/cALL", "show", "all", "J", "nolog"],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            proc.stderr.strip() or proc.stdout.strip() or "storcli failed"
        )

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid storcli JSON: {exc}") from exc


def load_bay_map(path):
    with open(path, "r", encoding="utf-8") as handle:
        mappings = json.load(handle)
    return {clean(mapping["serial"]): mapping for mapping in mappings}


def hba_state_metrics(status):
    text = clean(status)
    healthy = 1 if text in {"OK", "Optimal"} else 0
    degraded = 1 if text == "Degraded" else 0
    failed = 1 if text == "Failed" else 0
    return healthy, degraded, failed


def roc_temperature(hwcfg):
    for key in ("ROC temperature(Degree Celsius)", "ROC temperature(Degree Celcius)"):
        temp = parse_number(hwcfg.get(key))
        if temp is not None:
            return temp
    return None


def drive_identifier(controller, enclosure, slot):
    if enclosure:
        return f"Drive /c{controller}/e{enclosure}/s{slot}"
    return f"Drive /c{controller}/s{slot}"


def parse_visible_drive(controller_id, basic_drive, detail_map, bay_map):
    enclosure_slot = clean(basic_drive.get("EID:Slt"))
    enclosure = ""
    slot = ""
    if enclosure_slot:
        if ":" in enclosure_slot:
            enclosure, slot = [clean(part) for part in enclosure_slot.split(":", 1)]
        else:
            slot = enclosure_slot
    drive_key = drive_identifier(controller_id, enclosure, slot)
    detail = detail_map.get(f"{drive_key} - Detailed Information", {})
    state = detail.get(f"{drive_key} State", {})
    attributes = detail.get(f"{drive_key} Device attributes", {})
    settings = detail.get(f"{drive_key} Policies/Settings", {})

    serial = clean(attributes.get("SN"))
    bay_mapping = bay_map.get(serial)

    record = {
        "controller": clean(controller_id),
        "controller_enclosure": enclosure,
        "controller_slot": slot,
        "disk_id": clean(basic_drive.get("DID")),
        "interface": clean(basic_drive.get("Intf")),
        "media": clean(basic_drive.get("Med")),
        "model": clean(attributes.get("Model Number") or basic_drive.get("Model")),
        "state": clean(basic_drive.get("State")),
        "firmware": clean(attributes.get("Firmware Revision")),
        "serial": serial,
        "bay": "",
        "bay_row": "",
        "bay_col": "",
        "link_speed_gbps": parse_speed_gbps(attributes.get("Link Speed")),
        "connected_port": parse_connected_port(settings.get("Connected Port Number")),
        "media_errors": parse_number(state.get("Media Error Count")),
        "other_errors": parse_number(state.get("Other Error Count")),
        "predictive_errors": parse_number(state.get("Predictive Failure Count")),
        "smart_alerted": None,
    }

    smart_alert = clean(state.get("S.M.A.R.T alert flagged by drive"))
    if smart_alert == "Yes":
        record["smart_alerted"] = 1
    elif smart_alert == "No":
        record["smart_alerted"] = 0

    if bay_mapping:
        record["bay"] = clean(bay_mapping.get("bay"))
        record["bay_row"] = clean(bay_mapping.get("row"))
        record["bay_col"] = clean(bay_mapping.get("col"))

    return record


def render_metrics(data, bay_map):
    lines = metric_headers()
    visible_by_serial = {}
    successful_controllers = set()

    for controller in data.get("Controllers", []):
        command_status = controller.get("Command Status", {})
        controller_id = clean(command_status.get("Controller", "unknown"))
        controller_labels = {"controller": controller_id}
        if clean(command_status.get("Status")) != "Success":
            emit_metric(
                lines, "host_observability_hba_collect_success", 0, controller_labels
            )
            continue

        response = controller.get("Response Data", {})
        basics = response.get("Basics", {})
        version = response.get("Version", {})
        status = response.get("Status", {})
        hwcfg = response.get("HwCfg", {})
        controller_id = clean(basics.get("Controller", controller_id))
        controller_labels = {"controller": controller_id}
        controller_status = clean(status.get("Controller Status"))
        healthy, degraded, failed = hba_state_metrics(controller_status)
        successful_controllers.add(controller_id)

        emit_metric(
            lines, "host_observability_hba_collect_success", 1, controller_labels
        )
        emit_metric(
            lines,
            "host_observability_hba_info",
            1,
            {
                "adapter_type": clean(basics.get("Adapter Type")),
                "controller": controller_id,
                "driver": clean(version.get("Driver Name")),
                "firmware_version": clean(version.get("Firmware Version")),
                "model": clean(basics.get("Model")),
                "serial": clean(basics.get("Serial Number")),
                "status": controller_status,
            },
        )
        emit_metric(
            lines,
            "host_observability_hba_temperature_celsius",
            roc_temperature(hwcfg),
            {
                "controller": controller_id,
                "sensor": "roc",
            },
        )
        emit_metric(lines, "host_observability_hba_healthy", healthy, controller_labels)
        emit_metric(
            lines, "host_observability_hba_degraded", degraded, controller_labels
        )
        emit_metric(lines, "host_observability_hba_failed", failed, controller_labels)
        emit_metric(
            lines,
            "host_observability_hba_memory_correctable_errors",
            parse_number(status.get("Memory Correctable Errors")),
            controller_labels,
        )
        emit_metric(
            lines,
            "host_observability_hba_memory_uncorrectable_errors",
            parse_number(status.get("Memory Uncorrectable Errors")),
            controller_labels,
        )
        emit_metric(
            lines,
            "host_observability_hba_backend_ports",
            parse_number(hwcfg.get("Backend Port Count")),
            controller_labels,
        )

        physical_device_information = response.get("Physical Device Information", {})
        visible_devices = []
        for key, basic_drive in physical_device_information.items():
            if key.endswith(" - Detailed Information"):
                continue
            if not isinstance(basic_drive, list) or not basic_drive:
                continue
            visible_devices.append(
                parse_visible_drive(
                    controller_id, basic_drive[0], physical_device_information, bay_map
                )
            )

        emit_metric(
            lines,
            "host_observability_hba_physical_drives",
            len(visible_devices),
            controller_labels,
        )

        for drive in visible_devices:
            if drive["serial"]:
                visible_by_serial[drive["serial"]] = drive
            common_labels = {
                "bay": drive["bay"],
                "bay_col": drive["bay_col"],
                "bay_row": drive["bay_row"],
                "controller": drive["controller"],
                "controller_enclosure": drive["controller_enclosure"],
                "controller_slot": drive["controller_slot"],
                "model": drive["model"],
                "serial": drive["serial"],
            }
            emit_metric(lines, "host_observability_hba_drive_visible", 1, common_labels)
            emit_metric(
                lines,
                "host_observability_hba_drive_info",
                1,
                common_labels
                | {
                    "disk_id": drive["disk_id"],
                    "firmware": drive["firmware"],
                    "interface": drive["interface"],
                    "media": drive["media"],
                    "state": drive["state"],
                },
            )
            emit_metric(
                lines,
                "host_observability_hba_drive_link_speed_gbps",
                drive["link_speed_gbps"],
                common_labels,
            )
            emit_metric(
                lines,
                "host_observability_hba_drive_connected_port",
                drive["connected_port"],
                common_labels,
            )
            emit_metric(
                lines,
                "host_observability_hba_drive_media_errors",
                drive["media_errors"],
                common_labels,
            )
            emit_metric(
                lines,
                "host_observability_hba_drive_other_errors",
                drive["other_errors"],
                common_labels,
            )
            emit_metric(
                lines,
                "host_observability_hba_drive_predictive_errors",
                drive["predictive_errors"],
                common_labels,
            )
            emit_metric(
                lines,
                "host_observability_hba_drive_smart_alerted",
                drive["smart_alerted"],
                common_labels,
            )

    if not successful_controllers:
        emit_metric(
            lines,
            "host_observability_hba_collect_success",
            0,
            {"controller": "all"},
        )

    for serial, mapping in bay_map.items():
        if serial in visible_by_serial:
            continue
        emit_metric(
            lines,
            "host_observability_hba_drive_visible",
            0,
            {
                "bay": clean(mapping.get("bay")),
                "bay_col": clean(mapping.get("col")),
                "bay_row": clean(mapping.get("row")),
                "controller": "",
                "controller_enclosure": "",
                "controller_slot": "",
                "model": clean(mapping.get("model")),
                "serial": serial,
            },
        )

    return "\n".join(lines) + "\n"


def write_atomic(path, content):
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=out_path.parent,
        prefix=f".{out_path.name}.",
        delete=False,
    ) as handle:
        handle.write(content)
        tmp_name = handle.name
    os.chmod(tmp_name, 0o644)
    os.replace(tmp_name, out_path)


def main():
    args = parse_args()
    error = None

    try:
        bay_map = load_bay_map(args.bay_map)
        storcli_json = load_storcli_json(args)
        content = render_metrics(storcli_json, bay_map)
    except Exception as exc:
        error = exc
        content = (
            "\n".join(
                metric_headers()
                + ['host_observability_hba_collect_success{controller="all"} 0']
            )
            + "\n"
        )

    write_atomic(args.output_file, content)
    if error is not None:
        print(f"hba-exporter: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
