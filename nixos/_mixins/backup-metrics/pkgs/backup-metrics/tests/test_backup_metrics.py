from __future__ import annotations

import json
from pathlib import Path

from prometheus_client import CollectorRegistry
from prometheus_client.parser import text_string_to_metric_families

from backup_metrics.cli import run_configure, run_record
from backup_metrics.metrics import configured_registry, result_registry
from backup_metrics.models import BackupJob, BackupState, JobsConfig, Outcome
from backup_metrics.state import read_state, updated_state, write_state
from backup_metrics.systemd import duration_from_timestamps


class FixedDuration:
    def __init__(self, duration: float) -> None:
        self.duration = duration

    def duration_seconds(self, unit_name: str) -> float:
        del unit_name
        return self.duration


def job() -> BackupJob:
    return BackupJob(
        backup_job="media/local", backup_title='Media "local"', phase="local", unit="backup.service"
    )


def sample_values(
    registry: CollectorRegistry,
) -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    return {
        (sample.name, tuple(sorted(sample.labels.items()))): sample.value
        for metric in registry.collect()
        for sample in metric.samples
    }


def test_failure_preserves_previous_success_and_records_duration() -> None:
    previous = BackupState(
        last_run_timestamp_seconds=50,
        last_success_timestamp_seconds=40,
        last_duration_seconds=3,
        last_success=True,
        service_result="success",
        exit_code="exited",
        exit_status="0",
    )
    state = updated_state(
        previous,
        Outcome("exit-code", "exited", "1"),
        now=100,
        duration=2.5,
    )
    assert state.last_run_timestamp_seconds == 100
    assert state.last_success_timestamp_seconds == 40
    assert state.last_duration_seconds == 2.5
    assert not state.last_success


def test_success_updates_success_timestamp() -> None:
    state = updated_state(None, Outcome("success", "exited", "0"), now=100, duration=4)
    assert state.last_success
    assert state.last_success_timestamp_seconds == 100


def test_metrics_are_exposed_as_structured_samples() -> None:
    configured = sample_values(configured_registry(JobsConfig(jobs=(job(),))))
    configured_labels = tuple(
        sorted(
            {
                "backup_job": "media/local",
                "backup_title": 'Media "local"',
                "phase": "local",
                "unit": "backup.service",
            }.items()
        )
    )
    assert configured[("host_observability_backup_job_configured", configured_labels)] == 1

    state = BackupState(
        last_run_timestamp_seconds=100,
        last_success_timestamp_seconds=90,
        last_duration_seconds=2.5,
        last_success=False,
        service_result="exit-code",
        exit_code="exited",
        exit_status="1",
    )
    result = sample_values(result_registry(job(), state))
    assert result[("host_observability_backup_last_duration_seconds", configured_labels)] == 2.5
    assert result[("host_observability_backup_last_success", configured_labels)] == 0


def test_state_round_trip_is_typed_and_world_readable(tmp_path: Path) -> None:
    path = tmp_path / "state" / "backup.json"
    state = BackupState(
        last_run_timestamp_seconds=100,
        last_success_timestamp_seconds=90,
        last_duration_seconds=2.5,
        last_success=False,
        service_result="exit-code",
        exit_code="exited",
        exit_status="1",
    )
    write_state(path, state)
    assert read_state(path) == state
    assert path.stat().st_mode & 0o777 == 0o644
    path.write_text("not json", encoding="utf-8")
    assert read_state(path) is None


def test_cli_records_service_environment_and_writes_parseable_metrics(tmp_path: Path) -> None:
    state_path = tmp_path / "state.json"
    metrics_path = tmp_path / "backup.prom"
    run_record(
        [
            "--backup-job",
            "local",
            "--backup-title",
            "Local backup",
            "--phase",
            "local",
            "--unit",
            "backup.service",
            "--state-file",
            str(state_path),
            "--metrics-file",
            str(metrics_path),
        ],
        {"SERVICE_RESULT": "success", "EXIT_CODE": "exited", "EXIT_STATUS": "0"},
        FixedDuration(3.25),
        now=123,
    )
    state = read_state(state_path)
    assert state is not None and state.last_success and state.last_duration_seconds == 3.25
    families = list(text_string_to_metric_families(metrics_path.read_text(encoding="utf-8")))
    assert {family.name for family in families} >= {
        "host_observability_backup_last_duration_seconds",
        "host_observability_backup_last_result_info",
    }


def test_cli_configures_all_declared_jobs(tmp_path: Path) -> None:
    config_path = tmp_path / "jobs.json"
    metrics_path = tmp_path / "configured.prom"
    config_path.write_text(
        json.dumps({"jobs": [job().model_dump(mode="json")]}),
        encoding="utf-8",
    )
    run_configure(["--config", str(config_path), "--metrics-file", str(metrics_path)])
    families = list(text_string_to_metric_families(metrics_path.read_text(encoding="utf-8")))
    samples = [sample for family in families for sample in family.samples]
    assert len(samples) == 1
    assert samples[0].labels["backup_job"] == "media/local"


def test_duration_rejects_missing_or_backwards_timestamps() -> None:
    assert duration_from_timestamps(1_000_000, 3_500_000) == 2.5
    assert duration_from_timestamps(0, 3_500_000) == 0
    assert duration_from_timestamps(3_500_000, 1_000_000) == 0
