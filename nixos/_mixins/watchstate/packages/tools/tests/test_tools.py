from __future__ import annotations

import sqlite3
import tarfile
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path

import bcrypt

import pytest

from watchstate_tools.cli import run_auth, run_backup
from watchstate_tools.runtime import PodmanRuntime


class InMemoryRuntime:
    def __init__(self) -> None:
        self.triggered = False

    def trigger_backup(self) -> None:
        self.triggered = True


def test_authentication_environment_is_atomic_and_verifiable(tmp_path: Path) -> None:
    password_file = tmp_path / "password"
    output = tmp_path / "auth.env"
    password_file.write_text("secret\n", encoding="utf-8")

    run_auth(
        [
            "--system-user",
            "media-owner",
            "--password-file",
            str(password_file),
            "--output",
            str(output),
        ]
    )

    values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
    assert values["WS_SYSTEM_USER"] == "media-owner"
    encoded_hash = values["WS_SYSTEM_PASSWORD"].removeprefix("ws_hash@:")
    assert bcrypt.checkpw(b"secret", encoded_hash.encode())
    assert output.stat().st_mode & 0o777 == 0o400


def create_database(path: Path) -> None:
    path.parent.mkdir(parents=True)
    with closing(sqlite3.connect(path)) as database:
        database.execute("CREATE TABLE state (name TEXT NOT NULL)")
        database.execute("INSERT INTO state VALUES ('preserved')")
        database.commit()


def create_old_archives(staging_dir: Path, count: int) -> None:
    for index in range(count):
        archive = staging_dir / f"watchstate-backup-2025010{index}T000000Z.tar.gz"
        archive.write_bytes(b"old")
        archive.touch()


def test_backup_snapshots_database_archives_state_and_prunes(tmp_path: Path) -> None:
    data_dir = tmp_path / "data"
    staging_dir = tmp_path / "staging"
    staging_dir.mkdir()
    database_path = data_dir / "db/watchstate_v02.db"
    create_database(database_path)
    (data_dir / "settings.json").write_text("{}", encoding="utf-8")
    (data_dir / "db/watchstate_v02.db-wal").write_bytes(b"not-a-real-wal")
    create_old_archives(staging_dir, 8)
    runtime = InMemoryRuntime()

    destination = run_backup(
        [
            "--data-dir",
            str(data_dir),
            "--staging-dir",
            str(staging_dir),
            "--keep",
            "7",
        ],
        lambda _socket, _container: runtime,
        now=lambda: datetime(2026, 8, 4, 12, 30, tzinfo=UTC),
    )

    assert runtime.triggered is True
    assert destination.name == "watchstate-backup-20260804T123000Z.tar.gz"
    assert destination.stat().st_mode & 0o777 == 0o640
    assert len(tuple(staging_dir.glob("watchstate-backup-*.tar.gz"))) == 7

    extract_dir = tmp_path / "extract"
    with tarfile.open(destination) as archive:
        archive.extractall(extract_dir, filter="data")
    assert (extract_dir / "state/settings.json").read_text(encoding="utf-8") == "{}"
    assert not (extract_dir / "state/db/watchstate_v02.db-wal").exists()
    with closing(sqlite3.connect(extract_dir / "state/db/watchstate_v02.db")) as database:
        assert database.execute("SELECT name FROM state").fetchone() == ("preserved",)


def test_native_podman_boundary_reports_unavailable_socket(tmp_path: Path) -> None:
    runtime = PodmanRuntime(
        f"http+unix://{tmp_path}/missing.sock",
        "watchstate",
    )

    with pytest.raises(RuntimeError, match="Unable to trigger"):
        runtime.trigger_backup()
