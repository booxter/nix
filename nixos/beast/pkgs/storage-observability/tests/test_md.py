from __future__ import annotations

from pathlib import Path

from beast_storage_observability.md import MdExporter, MdMetrics

from .metrics import samples, text_samples, value


def write_array(
    root: Path,
    device: str,
    *,
    action: str,
    raid_disks: str,
    degraded: str | None = None,
    completed: str | None = None,
    speed: str | None = None,
) -> Path:
    directory = root / device / "md"
    directory.mkdir(parents=True)
    (directory / "sync_action").write_text(action, encoding="utf-8")
    (directory / "raid_disks").write_text(raid_disks, encoding="utf-8")
    for name, content in (
        ("degraded", degraded),
        ("sync_completed", completed),
        ("sync_speed", speed),
    ):
        if content is not None:
            (directory / name).write_text(content, encoding="utf-8")
    return directory


def test_collects_active_sync_progress_and_reshape_disk_counts(tmp_path: Path) -> None:
    directory = write_array(
        tmp_path,
        "md127",
        action="reshape\n",
        raid_disks="11 (10)\n",
        degraded="1\n",
        completed="100 / 400\n",
        speed="25\n",
    )
    metrics = MdMetrics()

    metrics.collect_array(directory)

    parsed = samples(metrics.registry)
    assert (
        value(
            parsed,
            "host_observability_md_sync_action_info",
            device="md127",
            action="reshape",
            action_title="Reshape",
        )
        == 1
    )
    assert (
        value(
            parsed,
            "host_observability_md_sync_active",
            device="md127",
            action="reshape",
        )
        == 1
    )
    assert (
        value(
            parsed,
            "host_observability_md_sync_progress_percent",
            device="md127",
        )
        == 25
    )
    assert (
        value(
            parsed,
            "host_observability_md_sync_speed_bytes_per_second",
            device="md127",
        )
        == 25600
    )
    assert value(parsed, "host_observability_md_sync_eta_seconds", device="md127") == 6
    assert (
        value(
            parsed,
            "host_observability_md_raid_disks",
            device="md127",
            phase="current",
        )
        == 11
    )
    assert (
        value(
            parsed,
            "host_observability_md_raid_disks",
            device="md127",
            phase="previous",
        )
        == 10
    )
    assert value(parsed, "host_observability_md_degraded", device="md127") == 1


def test_idle_array_defaults_missing_activity_files_to_zero(tmp_path: Path) -> None:
    directory = write_array(tmp_path, "md0", action="idle", raid_disks="2")
    metrics = MdMetrics()

    metrics.collect_array(directory)

    parsed = samples(metrics.registry)
    assert value(parsed, "host_observability_md_sync_active", device="md0") == 0
    assert value(parsed, "host_observability_md_sync_total_sectors", device="md0") == 0
    assert value(parsed, "host_observability_md_sync_eta_seconds", device="md0") == 0
    assert (
        value(
            parsed,
            "host_observability_md_raid_disks",
            device="md0",
            phase="previous",
        )
        == 2
    )
    assert value(parsed, "host_observability_md_degraded", device="md0") == 0


def test_exporter_discovers_arrays_and_atomically_publishes_textfile(tmp_path: Path) -> None:
    root = tmp_path / "sys" / "block"
    write_array(root, "md0", action="idle", raid_disks="2")
    write_array(root, "md127", action="check", raid_disks="11")
    output = tmp_path / "textfiles" / "md-sync.prom"

    MdExporter(root).run(output)

    parsed = text_samples(output.read_text(encoding="utf-8"))
    assert value(parsed, "host_observability_md_degraded", device="md0") == 0
    assert value(parsed, "host_observability_md_degraded", device="md127") == 0
    assert output.stat().st_mode & 0o777 == 0o644
