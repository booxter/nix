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
    mode: int = 0o600,
    uid: int | None = None,
    gid: int | None = None,
) -> Iterator[Path]:
    """Yield a temporary sibling and durably replace path on success."""
    path.parent.mkdir(parents=True, exist_ok=True)
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
            os.fchmod(descriptor, mode)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


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
    with atomic_path(path, mode=mode, uid=uid, gid=gid) as temporary:
        temporary.write_text(content, encoding=encoding)
