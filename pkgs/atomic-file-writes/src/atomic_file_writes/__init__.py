from __future__ import annotations

import os
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path


def _sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def atomic_path(
    path: Path,
    *,
    mode: int | None = None,
    create_mode: int = 0o600,
    uid: int | None = None,
    gid: int | None = None,
) -> Iterator[Path]:
    """Yield a temporary sibling and durably replace path on success."""
    path.parent.mkdir(parents=True, exist_ok=True)
    effective_mode = mode
    if effective_mode is None:
        effective_mode = path.stat().st_mode & 0o777 if path.exists() else create_mode
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        yield temporary
        descriptor = os.open(temporary, os.O_RDONLY)
        try:
            if uid is not None or gid is not None:
                os.fchown(
                    descriptor,
                    uid if uid is not None else -1,
                    gid if gid is not None else -1,
                )
            os.fchmod(descriptor, effective_mode)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        temporary.replace(path)
        _sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def write_text_atomic(
    path: Path,
    content: str,
    *,
    mode: int | None = None,
    create_mode: int = 0o600,
    uid: int | None = None,
    gid: int | None = None,
    encoding: str = "utf-8",
) -> None:
    """Durably replace a text file without exposing partial content."""
    with atomic_path(
        path,
        mode=mode,
        create_mode=create_mode,
        uid=uid,
        gid=gid,
    ) as temporary:
        temporary.write_text(content, encoding=encoding)


def write_bytes_atomic(
    path: Path,
    content: bytes,
    *,
    mode: int | None = None,
    create_mode: int = 0o600,
    uid: int | None = None,
    gid: int | None = None,
) -> None:
    """Durably replace a binary file without exposing partial content."""
    with atomic_path(
        path,
        mode=mode,
        create_mode=create_mode,
        uid=uid,
        gid=gid,
    ) as temporary:
        temporary.write_bytes(content)
