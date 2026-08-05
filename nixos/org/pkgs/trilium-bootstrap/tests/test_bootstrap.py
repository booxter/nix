from __future__ import annotations

import io
import socket
import sqlite3
import sys
from contextlib import closing
from collections.abc import Sequence
from pathlib import Path

from trilium_bootstrap.cli import run

FIXTURE_SERVER = Path(__file__).with_name("fixture_server.py")


def unused_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def create_database(
    path: Path,
    *,
    initialized: bool = True,
    password_set: bool = True,
    include_mfa_enabled: bool = True,
    include_mfa_method: bool = True,
) -> None:
    values = [
        ("initialized", "true" if initialized else "false"),
        ("passwordVerificationHash", "configured" if password_set else ""),
    ]
    if include_mfa_enabled:
        values.append(("mfaEnabled", "false"))
    if include_mfa_method:
        values.append(("mfaMethod", "local"))
    with closing(sqlite3.connect(path)) as connection:
        with connection:
            connection.execute("CREATE TABLE options (name TEXT PRIMARY KEY, value TEXT NOT NULL)")
            connection.executemany("INSERT INTO options(name, value) VALUES (?, ?)", values)


def read_options(path: Path) -> dict[str, str]:
    with closing(sqlite3.connect(path)) as connection:
        return dict(connection.execute("SELECT name, value FROM options"))


def invoke(
    tmp_path: Path,
    server_arguments: Sequence[str] = (),
    *,
    database: Path | None = None,
    timeout: float = 2,
) -> tuple[int, str]:
    database_path = database or tmp_path / "document.db"
    password_file = tmp_path / "password"
    password_file.write_bytes(b"break & glass")
    stderr = io.StringIO()
    port = unused_port()
    arguments = [
        "--database",
        str(database_path),
        "--base-url",
        f"http://127.0.0.1:{port}",
        "--password-file",
        str(password_file),
        "--startup-timeout-seconds",
        str(timeout),
        "--poll-seconds",
        "0.01",
        "--server-command",
        sys.executable,
        str(FIXTURE_SERVER),
        "--port",
        str(port),
        "--database",
        str(database_path),
        *server_arguments,
    ]
    status = run(arguments, stderr)
    return status, stderr.getvalue()


def test_fresh_bootstrap_initializes_password_and_oidc(tmp_path: Path) -> None:
    database = tmp_path / "document.db"

    status, stderr = invoke(tmp_path, database=database)

    assert status == 0
    assert stderr == ""
    options = read_options(database)
    assert options["initialized"] == "true"
    assert options["passwordVerificationHash"] == "configured"
    assert options["mfaEnabled"] == "true"
    assert options["mfaMethod"] == "oauth"


def test_complete_database_does_not_launch_server(tmp_path: Path) -> None:
    database = tmp_path / "document.db"
    create_database(database)
    password_file = tmp_path / "password"
    password_file.write_text("unused")
    stderr = io.StringIO()

    status = run(
        [
            "--database",
            str(database),
            "--base-url",
            "http://127.0.0.1:1",
            "--password-file",
            str(password_file),
            "--server-command",
            "/definitely/not/a/server",
        ],
        stderr,
    )

    assert status == 0
    assert stderr.getvalue() == ""
    options = read_options(database)
    assert options["mfaEnabled"] == "true"
    assert options["mfaMethod"] == "oauth"


def test_existing_document_gets_missing_password(tmp_path: Path) -> None:
    database = tmp_path / "document.db"
    create_database(database, password_set=False)

    status, stderr = invoke(tmp_path, database=database)

    assert status == 0
    assert stderr == ""
    assert read_options(database)["passwordVerificationHash"] == "configured"


def test_early_server_exit_is_reported(tmp_path: Path) -> None:
    status, stderr = invoke(tmp_path, ["--exit-immediately"])

    assert status == 1
    assert "exited before bootstrap completed" in stderr


def test_invalid_status_times_out(tmp_path: Path) -> None:
    status, stderr = invoke(tmp_path, ["--invalid-status"], timeout=0.1)

    assert status == 1
    assert "timed out waiting" in stderr


def test_rejected_password_leaves_mfa_unchanged(tmp_path: Path) -> None:
    database = tmp_path / "document.db"

    status, stderr = invoke(tmp_path, ["--reject-password"], database=database)

    assert status == 1
    assert "returned HTTP 500" in stderr
    options = read_options(database)
    assert options["mfaEnabled"] == "false"
    assert options["mfaMethod"] == "local"


def test_missing_mfa_option_rolls_back_transaction(tmp_path: Path) -> None:
    database = tmp_path / "document.db"
    create_database(database, include_mfa_method=False)

    status, stderr = invoke(tmp_path, database=database)

    assert status == 1
    assert "missing the mfaMethod option" in stderr
    assert read_options(database)["mfaEnabled"] == "false"


def test_empty_password_is_rejected_before_server_start(tmp_path: Path) -> None:
    database = tmp_path / "document.db"
    password_file = tmp_path / "password"
    password_file.write_bytes(b"")
    stderr = io.StringIO()

    status = run(
        [
            "--database",
            str(database),
            "--base-url",
            "http://127.0.0.1:1",
            "--password-file",
            str(password_file),
            "--server-command",
            "/definitely/not/a/server",
        ],
        stderr,
    )

    assert status == 1
    assert "password is empty" in stderr.getvalue()


def test_missing_password_file_is_reported_before_server_start(tmp_path: Path) -> None:
    stderr = io.StringIO()

    status = run(
        [
            "--database",
            str(tmp_path / "document.db"),
            "--base-url",
            "http://127.0.0.1:1",
            "--password-file",
            str(tmp_path / "missing-password"),
            "--server-command",
            "/definitely/not/a/server",
        ],
        stderr,
    )

    assert status == 1
    assert "failed to read Trilium password" in stderr.getvalue()
