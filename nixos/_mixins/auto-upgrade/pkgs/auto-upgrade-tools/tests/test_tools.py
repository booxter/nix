from __future__ import annotations

import io
import json
from datetime import date
from pathlib import Path

import pytest
from prometheus_client.parser import text_string_to_metric_families
from pydantic import ValidationError

from auto_upgrade_tools.cli import guard, run
from auto_upgrade_tools.metrics import write_hold_metrics, write_success_metric
from auto_upgrade_tools.model import UpgradeConfig
from auto_upgrade_tools.reboot import REBOOT_MESSAGE, reboot_required, schedule_reboot_if_needed


def load_config(document: dict[str, object]) -> UpgradeConfig:
    return UpgradeConfig.model_validate(document)


def metric_values(path: Path) -> dict[str, float]:
    return {
        sample.name: float(sample.value)
        for family in text_string_to_metric_families(path.read_text(encoding="utf-8"))
        for sample in family.samples
    }


def test_hold_model_rejects_invalid_ranges_and_fields() -> None:
    with pytest.raises(ValidationError):
        load_config(
            {
                "hostname": "host",
                "holds": [{"startDate": "2026-08-10", "stopDate": "2026-08-09"}],
            }
        )
    with pytest.raises(ValidationError):
        load_config({"hostname": "host", "holds": [], "unexpected": True})


def test_guard_uses_inclusive_hold_dates() -> None:
    config = load_config(
        {
            "hostname": "media",
            "holds": [{"startDate": "2026-08-04", "stopDate": "2026-08-10"}],
        }
    )
    stderr = io.StringIO()
    assert guard(config, date(2026, 8, 4), stderr) == 1
    assert "media" in stderr.getvalue()
    assert "2026-08-04..2026-08-10" in stderr.getvalue()
    assert guard(config, date(2026, 8, 11), io.StringIO()) == 0


def test_hold_metrics_describe_the_first_active_window(tmp_path: Path) -> None:
    config = load_config(
        {
            "hostname": "media",
            "holds": [
                {"startDate": "2026-08-01", "stopDate": "2026-08-03"},
                {"startDate": "2026-08-04", "stopDate": "2026-08-10"},
            ],
        }
    )
    output = tmp_path / "nested" / "hold.prom"
    write_hold_metrics(output, config, date(2026, 8, 4))

    values = metric_values(output)
    assert values["node_nixos_upgrade_hold_active"] == 1
    assert values["node_nixos_upgrade_hold_start_time_seconds"] > 0
    assert (
        values["node_nixos_upgrade_hold_stop_time_seconds"]
        > values["node_nixos_upgrade_hold_start_time_seconds"]
    )
    assert output.stat().st_mode & 0o777 == 0o644


def test_inactive_and_success_metrics_have_expected_values(tmp_path: Path) -> None:
    config = load_config({"hostname": "media", "holds": []})
    hold_output = tmp_path / "hold.prom"
    success_output = tmp_path / "success.prom"

    write_hold_metrics(hold_output, config, date(2026, 8, 4))
    write_success_metric(success_output, 1_754_275_200)

    assert metric_values(hold_output) == {
        "node_nixos_upgrade_hold_active": 0,
        "node_nixos_upgrade_hold_start_time_seconds": 0,
        "node_nixos_upgrade_hold_stop_time_seconds": 0,
    }
    assert (
        metric_values(success_output)["node_nixos_upgrade_last_success_time_seconds"]
        == 1_754_275_200
    )
    assert success_output.stat().st_mode & 0o777 == 0o644


def test_reboot_decision_compares_all_profile_links(tmp_path: Path) -> None:
    booted = tmp_path / "booted"
    current = tmp_path / "current"
    booted.mkdir()
    current.mkdir()
    for name in ("initrd", "kernel", "kernel-modules"):
        (booted / name).symlink_to(f"/nix/store/{name}-one")
        (current / name).symlink_to(f"/nix/store/{name}-one")

    assert not reboot_required(booted, current)
    (current / "kernel").unlink()
    (current / "kernel").symlink_to("/nix/store/kernel-two")
    assert reboot_required(booted, current)


def test_config_loads_generated_json(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps(
            {
                "hostname": "media",
                "holds": [{"startDate": "2026-08-04", "stopDate": "2026-08-10"}],
            }
        ),
        encoding="utf-8",
    )
    assert UpgradeConfig.load(path).active_hold(date(2026, 8, 5)) is not None


def test_cli_guard_and_metric_workflow(tmp_path: Path) -> None:
    today = date.today().isoformat()
    config = tmp_path / "config.json"
    output = tmp_path / "hold.prom"
    success = tmp_path / "success.prom"
    config.write_text(
        json.dumps(
            {
                "hostname": "media",
                "holds": [{"startDate": today, "stopDate": today}],
            }
        ),
        encoding="utf-8",
    )
    stderr = io.StringIO()

    assert run(["guard", "--config", str(config)], stderr) == 1
    assert run(["write-hold-metrics", "--config", str(config), "--output", str(output)]) == 0
    assert run(["write-success-metric", "--output", str(success)]) == 0
    assert "within hold" in stderr.getvalue()
    assert metric_values(output)["node_nixos_upgrade_hold_active"] == 1
    assert metric_values(success)["node_nixos_upgrade_last_success_time_seconds"] > 0


class RecordingScheduler:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def schedule(self, message: str) -> None:
        self.messages.append(message)


def test_changed_profile_schedules_one_reboot(tmp_path: Path) -> None:
    booted = tmp_path / "booted"
    current = tmp_path / "current"
    booted.mkdir()
    current.mkdir()
    for name in ("initrd", "kernel", "kernel-modules"):
        (booted / name).symlink_to(f"/nix/store/{name}-one")
        (current / name).symlink_to(f"/nix/store/{name}-one")
    (current / "kernel").unlink()
    (current / "kernel").symlink_to("/nix/store/kernel-two")
    scheduler = RecordingScheduler()

    assert schedule_reboot_if_needed(
        scheduler,
        booted_system=booted,
        current_system=current,
    )
    assert scheduler.messages == [REBOOT_MESSAGE]
