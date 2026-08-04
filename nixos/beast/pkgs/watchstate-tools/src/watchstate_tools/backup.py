from __future__ import annotations

import os
import shutil
import sqlite3
import tarfile
import tempfile
from collections.abc import Callable
from contextlib import closing
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .runtime import ContainerRuntime


@dataclass(frozen=True)
class BackupResult:
    archive: Path
    removed: tuple[Path, ...]


def copy_state(data_dir: Path, destination: Path) -> None:
    database_dir = (data_dir / "db").resolve()

    def ignore_database_files(directory: str, names: list[str]) -> set[str]:
        if Path(directory).resolve() != database_dir:
            return set()
        return {
            name
            for name in names
            if name
            in {
                "watchstate_v02.db",
                "watchstate_v02.db-shm",
                "watchstate_v02.db-wal",
            }
        }

    shutil.copytree(
        data_dir,
        destination,
        symlinks=True,
        copy_function=shutil.copy2,
        ignore=ignore_database_files,
    )


def snapshot_database(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with closing(sqlite3.connect(source)) as source_database:
        with closing(sqlite3.connect(destination)) as destination_database:
            source_database.backup(destination_database)


def archive_state(state_dir: Path, destination: Path) -> None:
    with tarfile.open(destination, "w:gz") as archive:
        archive.add(state_dir, arcname="state")


def prune_archives(staging_dir: Path, keep: int) -> tuple[Path, ...]:
    if keep < 0:
        raise ValueError("WatchState backup retention cannot be negative")
    archives = sorted(
        staging_dir.glob("watchstate-backup-*.tar.gz"),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
        reverse=True,
    )
    removed = tuple(archives[keep:])
    for path in removed:
        path.unlink()
    return removed


def create_backup(
    runtime: ContainerRuntime,
    *,
    data_dir: Path,
    staging_dir: Path,
    keep: int,
    now: Callable[[], datetime],
) -> BackupResult:
    runtime.trigger_backup()
    timestamp = now().astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
    archive_name = f"watchstate-backup-{timestamp}.tar.gz"
    with tempfile.TemporaryDirectory(prefix=".watchstate-backup.", dir=staging_dir) as work:
        work_dir = Path(work)
        state_dir = work_dir / "state"
        copy_state(data_dir, state_dir)
        snapshot_database(
            data_dir / "db/watchstate_v02.db",
            state_dir / "db/watchstate_v02.db",
        )
        temporary_archive = work_dir / archive_name
        archive_state(state_dir, temporary_archive)
        destination = staging_dir / archive_name
        shutil.copyfile(temporary_archive, destination)
        os.chmod(destination, 0o640)
    return BackupResult(
        archive=destination,
        removed=prune_archives(staging_dir, keep),
    )
