from __future__ import annotations

from pathlib import Path

from prometheus_client import CollectorRegistry, Gauge, write_to_textfile

from .models import BackupJob, BackupState, JobsConfig

PREFIX = "host_observability_backup"
JOB_LABELS = ("backup_job", "backup_title", "phase", "unit")


def _job_values(job: BackupJob) -> tuple[str, str, str, str]:
    return job.backup_job, job.backup_title, job.phase, job.unit


def configured_registry(configuration: JobsConfig) -> CollectorRegistry:
    registry = CollectorRegistry()
    configured = Gauge(
        f"{PREFIX}_job_configured",
        "Whether a backup job is configured on this host.",
        JOB_LABELS,
        registry=registry,
    )
    for job in configuration.jobs:
        configured.labels(*_job_values(job)).set(1)
    return registry


def result_registry(job: BackupJob, state: BackupState) -> CollectorRegistry:
    registry = CollectorRegistry()
    values = _job_values(job)
    for suffix, documentation, value in (
        (
            "last_run_timestamp_seconds",
            "Unix timestamp of the most recent backup job run.",
            state.last_run_timestamp_seconds,
        ),
        (
            "last_success_timestamp_seconds",
            "Unix timestamp of the most recent successful backup job run.",
            state.last_success_timestamp_seconds,
        ),
        (
            "last_duration_seconds",
            "Duration of the most recent backup job run in seconds.",
            state.last_duration_seconds,
        ),
        (
            "last_success",
            "Whether the most recent backup job run succeeded.",
            float(state.last_success),
        ),
    ):
        Gauge(f"{PREFIX}_{suffix}", documentation, JOB_LABELS, registry=registry).labels(
            *values
        ).set(value)

    result_labels = JOB_LABELS + ("service_result", "exit_code", "exit_status")
    Gauge(
        f"{PREFIX}_last_result_info",
        "Metadata about the most recent backup job result.",
        result_labels,
        registry=registry,
    ).labels(
        *values,
        state.service_result,
        state.exit_code,
        state.exit_status,
    ).set(1)
    return registry


def write_registry(path: Path, registry: CollectorRegistry) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_to_textfile(str(path), registry)
