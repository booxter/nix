from __future__ import annotations

from pathlib import Path

from atomic_file_writes import write_bytes_atomic
from pydantic import ValidationError

from .models import StateFile


def read_state(path: Path | None) -> StateFile:
    if path is None:
        return StateFile()
    try:
        return StateFile.model_validate_json(path.read_bytes())
    except (OSError, ValidationError):
        return StateFile()


def write_state(path: Path | None, state: StateFile) -> None:
    if path is not None:
        payload = state.model_dump_json().encode() + b"\n"
        write_bytes_atomic(path, payload, mode=0o600)


def write_metrics(path: Path, content: bytes) -> None:
    write_bytes_atomic(path, content, mode=0o644)


def read_password(path: Path) -> str:
    return path.read_text().rstrip("\n")
