from __future__ import annotations

import json
from pathlib import Path

from atomic_file_writes import write_text_atomic
from pydantic import ValidationError

from .models import BackupState, Outcome


def read_state(path: Path) -> BackupState | None:
    try:
        return BackupState.model_validate_json(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, ValidationError):
        return None


def updated_state(
    previous: BackupState | None,
    outcome: Outcome,
    *,
    now: float,
    duration: float,
) -> BackupState:
    return BackupState(
        last_run_timestamp_seconds=now,
        last_success_timestamp_seconds=(
            now
            if outcome.succeeded
            else (previous.last_success_timestamp_seconds if previous is not None else 0.0)
        ),
        last_duration_seconds=duration,
        last_success=outcome.succeeded,
        service_result=outcome.service_result,
        exit_code=outcome.exit_code,
        exit_status=outcome.exit_status,
    )


def write_state(path: Path, state: BackupState) -> None:
    content = json.dumps(state.model_dump(mode="json"), indent=2, sort_keys=True) + "\n"
    write_text_atomic(path, content, mode=0o644)
