from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest
from pydantic import ValidationError

from backup_artifact_tools.artifact import create_artifact
from backup_artifact_tools.cli import run
from backup_artifact_tools.model import ARTIFACT_ADAPTER, SQLiteArtifact


def sqlite_config(
    source: Path,
    destination: Path,
    *,
    extra_copies: list[dict[str, object]] | None = None,
) -> SQLiteArtifact:
    artifact = ARTIFACT_ADAPTER.validate_python(
        {
            "kind": "sqlite",
            "databasePath": str(source),
            "destinationDir": str(destination),
            "extraCopies": extra_copies or [],
        }
    )
    assert isinstance(artifact, SQLiteArtifact)
    return artifact


def test_sqlite_backup_and_extra_files_are_published(tmp_path: Path) -> None:
    source = tmp_path / "state" / "app.db"
    source.parent.mkdir()
    with sqlite3.connect(source) as database:
        database.execute("CREATE TABLE item (value TEXT NOT NULL)")
        database.execute("INSERT INTO item VALUES ('preserved')")
    settings = tmp_path / "state" / "settings.json"
    settings.write_text('{"enabled": true}\n', encoding="utf-8")
    destination = tmp_path / "backup" / "latest"
    config = sqlite_config(
        source,
        destination,
        extra_copies=[
            {
                "source": str(settings),
                "mode": "0600",
                "optional": False,
            }
        ],
    )

    create_artifact(config, now=datetime(2026, 8, 4, 12, 30, tzinfo=UTC))

    with sqlite3.connect(destination / "app.db") as backup:
        assert backup.execute("SELECT value FROM item").fetchone() == ("preserved",)
    copied = destination / "settings.json"
    assert copied.read_text(encoding="utf-8") == '{"enabled": true}\n'
    assert copied.stat().st_mode & 0o777 == 0o600
    assert (destination / "created-at.txt").read_text(encoding="utf-8") == (
        "2026-08-04T12:30:00+00:00\n"
    )


def test_required_missing_extra_does_not_replace_existing_artifact(tmp_path: Path) -> None:
    source = tmp_path / "app.db"
    with sqlite3.connect(source) as database:
        database.execute("CREATE TABLE item (value TEXT NOT NULL)")
    destination = tmp_path / "backup" / "latest"
    destination.mkdir(parents=True)
    existing = destination / "app.db"
    existing.write_bytes(b"previous")
    config = sqlite_config(
        source,
        destination,
        extra_copies=[
            {
                "source": str(tmp_path / "missing.key"),
                "mode": "0600",
                "optional": False,
            }
        ],
    )

    with pytest.raises(FileNotFoundError, match="missing extra backup file"):
        create_artifact(config)
    assert existing.read_bytes() == b"previous"


def test_optional_missing_extra_preserves_previous_copy(tmp_path: Path) -> None:
    source = tmp_path / "app.db"
    with sqlite3.connect(source) as database:
        database.execute("CREATE TABLE item (value TEXT NOT NULL)")
    destination = tmp_path / "backup" / "latest"
    destination.mkdir(parents=True)
    previous = destination / "optional.json"
    previous.write_text("previous\n", encoding="utf-8")
    config = sqlite_config(
        source,
        destination,
        extra_copies=[
            {
                "source": str(tmp_path / "missing.json"),
                "mode": "0640",
                "optional": True,
            }
        ],
    )

    create_artifact(config)
    assert previous.read_text(encoding="utf-8") == "previous\n"


def test_model_rejects_invalid_database_names_and_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        ARTIFACT_ADAPTER.validate_python(
            {
                "kind": "postgresql",
                "database": "../app",
                "destinationDir": "/backup/latest",
                "executable": "/bin/pg_dump",
            }
        )
    with pytest.raises(ValidationError):
        ARTIFACT_ADAPTER.validate_python(
            {
                "kind": "postgresql",
                "database": "app",
                "destinationDir": "/backup/latest",
                "executable": "/bin/pg_dump",
                "typo": True,
            }
        )


def test_cli_loads_generated_json_and_creates_backup(tmp_path: Path) -> None:
    source = tmp_path / "app.db"
    with sqlite3.connect(source) as database:
        database.execute("CREATE TABLE item (value TEXT NOT NULL)")
        database.execute("INSERT INTO item VALUES ('cli')")
    destination = tmp_path / "backup" / "latest"
    config = tmp_path / "config.json"
    config.write_text(
        json.dumps(
            {
                "kind": "sqlite",
                "databasePath": str(source),
                "destinationDir": str(destination),
                "extraCopies": [],
            }
        ),
        encoding="utf-8",
    )

    assert run(["--config", str(config)]) == 0
    with sqlite3.connect(destination / "app.db") as backup:
        assert backup.execute("SELECT value FROM item").fetchone() == ("cli",)
