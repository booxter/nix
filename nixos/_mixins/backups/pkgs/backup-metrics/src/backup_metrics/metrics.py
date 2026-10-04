from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path

from atomic_file_writes import write_text_atomic
from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import BackupJob, BackupState, JobsConfig

PREFIX = "host_observability_backup"
JOB_LABELS = ("backup_job", "backup_title", "phase", "unit")


def _job_values(job: BackupJob) -> tuple[str, str, str, str]:
    return job.backup_job, job.backup_title, job.phase, job.unit


def backup_registry(
    configuration: JobsConfig, states: Mapping[str, BackupState]
) -> CollectorRegistry:
    registry = CollectorRegistry()
    configured = Gauge(
        f"{PREFIX}_job_configured",
        "Whether a backup job is configured on this host.",
        JOB_LABELS,
        registry=registry,
    )
    for job in configuration.jobs:
        configured.labels(*_job_values(job)).set(1)

    gauges = {}
    for suffix, documentation in (
        (
            "last_run_timestamp_seconds",
            "Unix timestamp of the most recent backup job run.",
        ),
        (
            "last_success_timestamp_seconds",
            "Unix timestamp of the most recent successful backup job run.",
        ),
        (
            "last_duration_seconds",
            "Duration of the most recent backup job run in seconds.",
        ),
        (
            "last_success",
            "Whether the most recent backup job run succeeded.",
        ),
    ):
        gauges[suffix] = Gauge(f"{PREFIX}_{suffix}", documentation, JOB_LABELS, registry=registry)

    result_labels = (*JOB_LABELS, "service_result", "exit_code", "exit_status")
    result = Gauge(
        f"{PREFIX}_last_result_info",
        "Metadata about the most recent backup job result.",
        result_labels,
        registry=registry,
    )
    for job in configuration.jobs:
        state = states.get(job.backup_job)
        if state is None:
            continue

        values = _job_values(job)
        for suffix, value in (
            ("last_run_timestamp_seconds", state.last_run_timestamp_seconds),
            ("last_success_timestamp_seconds", state.last_success_timestamp_seconds),
            ("last_duration_seconds", state.last_duration_seconds),
            ("last_success", float(state.last_success)),
        ):
            gauges[suffix].labels(*values).set(value)

        result.labels(*values, state.service_result, state.exit_code, state.exit_status).set(1)
    return registry


def write_registry(path: Path, registry: CollectorRegistry) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_text_atomic(path, generate_latest(registry).decode(), mode=0o644)
