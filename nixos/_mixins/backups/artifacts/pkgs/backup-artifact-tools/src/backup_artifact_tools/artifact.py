from __future__ import annotations

import os
import pwd
import shutil
import sqlite3
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Protocol

from .model import Artifact, ExtraCopy, MariaDBArtifact, PostgreSQLArtifact, SQLiteArtifact


class DatabaseDumper(Protocol):
    def dump(self, destination: Path) -> None: ...


@dataclass(frozen=True)
class ProcessDumper:
    arguments: tuple[str | Path, ...]
    user: str | None = None

    def dump(self, destination: Path) -> None:
        with destination.open("wb") as output:
            if self.user is None:
                subprocess.run(self.arguments, stdout=output, check=True)
                return

            account = pwd.getpwnam(self.user)
            subprocess.run(
                self.arguments,
                stdout=output,
                check=True,
                user=account.pw_uid,
                group=account.pw_gid,
                extra_groups=[],
            )


@dataclass(frozen=True)
class SQLiteDumper:
    source: Path

    def dump(self, destination: Path) -> None:
        if not self.source.is_file():
            raise FileNotFoundError(f"missing SQLite database at {self.source}")
        with sqlite3.connect(self.source) as source, sqlite3.connect(destination) as target:
            source.backup(target)


def dumper_for(config: Artifact) -> DatabaseDumper:
    if isinstance(config, PostgreSQLArtifact):
        return ProcessDumper(
            (config.executable, "--format=custom", config.database),
            user="postgres",
        )
    if isinstance(config, MariaDBArtifact):
        return ProcessDumper(
            (
                config.executable,
                "--user=root",
                "--socket=/run/mysqld/mysqld.sock",
                "--single-transaction",
                "--routines",
                "--events",
                "--triggers",
                "--hex-blob",
                "--databases",
                config.database,
            )
        )
    return SQLiteDumper(config.database_path)


def _prepare_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o750)
    path.chmod(0o750)


def _copy_extra(copy: ExtraCopy, staging: Path) -> Path | None:
    if not copy.source.is_file():
        if copy.optional:
            return None
        raise FileNotFoundError(f"missing extra backup file at {copy.source}")
    destination = staging / copy.source.name
    _prepare_directory(destination.parent)
    shutil.copyfile(copy.source, destination)
    destination.chmod(copy.numeric_mode)
    return destination


def create_artifact(
    config: Artifact,
    *,
    now: datetime | None = None,
    dumper: DatabaseDumper | None = None,
) -> None:
    backup_root = config.destination_dir.parent
    _prepare_directory(backup_root)
    _prepare_directory(config.destination_dir)
    timestamp = now or datetime.now().astimezone()

    with tempfile.TemporaryDirectory(prefix=".tmp.", dir=backup_root) as temporary:
        staging = Path(temporary)
        primary = staging / destination_filename(config)
        (dumper or dumper_for(config)).dump(primary)

        extra_files: list[Path] = []
        if isinstance(config, SQLiteArtifact):
            for copy in config.extra_copies:
                staged = _copy_extra(copy, staging)
                if staged is not None:
                    extra_files.append(staged)

        created_at = staging / "created-at.txt"
        created_at.write_text(timestamp.isoformat(timespec="seconds") + "\n", encoding="utf-8")

        os.replace(primary, config.destination_dir / primary.name)
        for staged in extra_files:
            relative = staged.relative_to(staging)
            destination = config.destination_dir / relative
            _prepare_directory(destination.parent)
            os.replace(staged, destination)
        os.replace(created_at, config.destination_dir / created_at.name)


def destination_filename(config: Artifact) -> str:
    if isinstance(config, PostgreSQLArtifact):
        return f"{config.database}.dump"
    if isinstance(config, MariaDBArtifact):
        return f"{config.database}.sql"
    return config.database_path.name
