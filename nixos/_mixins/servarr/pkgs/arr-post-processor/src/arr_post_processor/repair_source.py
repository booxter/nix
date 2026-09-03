from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from .errors import NeedsAttention


@dataclass(frozen=True)
class SourceRoot:
    name: str
    host_path: Path


@dataclass(frozen=True)
class LocatedSource:
    host_path: Path
    workspace_path: PurePosixPath
    root: SourceRoot


def locate_source(path: Path, roots: tuple[SourceRoot, ...]) -> LocatedSource:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise NeedsAttention(f"repair source is unavailable: {error}") from error
    if not resolved.is_file() and not resolved.is_dir():
        raise NeedsAttention(f"repair source is not a regular file or directory: {resolved}")
    for root in roots:
        root_path = root.host_path.resolve()
        if resolved == root_path or resolved.is_relative_to(root_path):
            relative = resolved.relative_to(root_path)
            return LocatedSource(
                host_path=resolved,
                workspace_path=PurePosixPath("input", root.name, *relative.parts),
                root=root,
            )
    raise NeedsAttention(f"repair source is outside the configured roots: {resolved}")


def source_fingerprint(
    source: LocatedSource, *, ignored_directories: frozenset[str] = frozenset()
) -> str:
    path = source.host_path
    entries: list[str] = []
    try:
        if path.is_file():
            stat = path.stat()
            entries.append(f"{path.name}\0{stat.st_size}\0{stat.st_mtime_ns}")
        else:
            for candidate in sorted(path.rglob("*")):
                relative = candidate.relative_to(path)
                if any(part in ignored_directories for part in relative.parts):
                    continue
                if candidate.is_symlink():
                    raise NeedsAttention(f"repair source contains a symlink: {candidate}")
                if not candidate.is_file():
                    continue
                resolved = candidate.resolve(strict=True)
                if not resolved.is_relative_to(source.root.host_path.resolve()):
                    raise NeedsAttention(f"repair source escapes its configured root: {candidate}")
                stat = resolved.stat()
                entries.append(f"{resolved.relative_to(path)}\0{stat.st_size}\0{stat.st_mtime_ns}")
    except OSError as error:
        raise NeedsAttention(f"cannot fingerprint repair source: {error}") from error
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()
