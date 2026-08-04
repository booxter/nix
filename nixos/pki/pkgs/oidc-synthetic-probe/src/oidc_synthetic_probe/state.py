from __future__ import annotations

import os
import tempfile
from pathlib import Path

from pydantic import ValidationError

from .models import StateFile


def read_state(path: Path | None) -> StateFile:
    if path is None:
        return StateFile()
    try:
        return StateFile.model_validate_json(path.read_bytes())
    except (OSError, ValidationError):
        return StateFile()


def _atomic_write(path: Path, content: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_state(path: Path | None, state: StateFile) -> None:
    if path is not None:
        payload = state.model_dump_json().encode() + b"\n"
        _atomic_write(path, payload, 0o600)


def write_metrics(path: Path, content: bytes) -> None:
    _atomic_write(path, content, 0o644)


def read_password(path: Path) -> str:
    return path.read_text().rstrip("\n")
