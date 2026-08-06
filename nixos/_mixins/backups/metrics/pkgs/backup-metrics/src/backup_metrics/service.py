from __future__ import annotations

from pathlib import Path

from .metrics import configured_registry, result_registry, write_registry
from .models import BackupJob, JobsConfig, Outcome
from .state import read_state, updated_state, write_state
from .systemd import DurationSource


def configure(config_path: Path, metrics_path: Path) -> None:
    configuration = JobsConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    write_registry(metrics_path, configured_registry(configuration))


def record(
    job: BackupJob,
    state_path: Path,
    metrics_path: Path,
    outcome: Outcome,
    duration_source: DurationSource,
    *,
    now: float,
) -> None:
    state = updated_state(
        read_state(state_path),
        outcome,
        now=now,
        duration=duration_source.duration_seconds(job.unit),
    )
    write_state(state_path, state)
    write_registry(metrics_path, result_registry(job, state))
