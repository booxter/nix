from __future__ import annotations

import os
import tempfile
from pathlib import Path


def _sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_text_atomic(
    path: Path,
    content: str,
    *,
    mode: int = 0o600,
    uid: int | None = None,
    gid: int | None = None,
    encoding: str = "utf-8",
) -> None:
    """Durably replace a text file without exposing partial content."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, mode="w", encoding=encoding) as output:
            if uid is not None or gid is not None:
                os.fchown(
                    output.fileno(),
                    uid if uid is not None else -1,
                    gid if gid is not None else -1,
                )
            os.fchmod(output.fileno(), mode)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)
