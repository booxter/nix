from __future__ import annotations

import io
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import mariadb
import pytest

from romm_tools.database import run


@pytest.fixture
def mariadb_socket(tmp_path: Path) -> Iterator[Path]:
    data_dir = tmp_path / "mysql"
    socket = tmp_path / "mysql.sock"
    subprocess.run(
        [
            "mariadb-install-db",
            "--no-defaults",
            f"--datadir={data_dir}",
            "--auth-root-authentication-method=normal",
            "--skip-test-db",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    process = subprocess.Popen(
        [
            "mariadbd",
            "--no-defaults",
            f"--datadir={data_dir}",
            f"--socket={socket}",
            f"--pid-file={tmp_path / 'mysql.pid'}",
            "--skip-networking",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if process.poll() is not None:
                pytest.fail(f"MariaDB exited with status {process.returncode}")
            try:
                connection = mariadb.connect(unix_socket=str(socket), user="root")
            except mariadb.Error:
                time.sleep(0.05)
            else:
                connection.close()
                break
        else:
            pytest.fail("timed out waiting for MariaDB")
        yield socket
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def invoke(socket: Path, password: str) -> tuple[int, str]:
    stderr = io.StringIO()
    status = run(
        ["--socket", str(socket)],
        {"DB_PASSWD": password},
        stderr,
    )
    return status, stderr.getvalue()


def connect_as_romm(socket: Path, password: str) -> mariadb.Connection:
    return mariadb.connect(
        unix_socket=str(socket),
        user="romm",
        password=password,
        database="romm",
    )


def test_initializes_database_and_verifies_escaped_credentials(mariadb_socket: Path) -> None:
    passwords = ["quote'", "dollar$", "backslash\\", "unicode-ß"]
    failures = {
        password: stderr
        for password in passwords
        for status, stderr in [invoke(mariadb_socket, password)]
        if status != 0
    }
    assert failures == {}

    password = passwords[-1]
    with connect_as_romm(mariadb_socket, password) as connection:
        with connection.cursor() as cursor:
            cursor.execute("CREATE TABLE native_test (value INTEGER NOT NULL)")
            cursor.execute("INSERT INTO native_test VALUES (42)")
            cursor.execute("SELECT value FROM native_test")
            assert cursor.fetchone() == (42,)


def test_rerun_rotates_existing_account_password(mariadb_socket: Path) -> None:
    assert invoke(mariadb_socket, "old-password")[0] == 0

    status, stderr = invoke(mariadb_socket, "new-password")

    assert status == 0
    assert stderr == ""
    with connect_as_romm(mariadb_socket, "new-password"):
        pass
    with pytest.raises(mariadb.OperationalError):
        connect_as_romm(mariadb_socket, "old-password")


@pytest.mark.parametrize("environment", [{}, {"DB_PASSWD": ""}])
def test_missing_or_empty_password_fails_without_connecting(
    environment: dict[str, str],
    tmp_path: Path,
) -> None:
    stderr = io.StringIO()

    status = run(["--socket", str(tmp_path / "missing.sock")], environment, stderr)

    assert status == 1
    assert "password" in stderr.getvalue()


def test_unavailable_database_reports_clean_error(tmp_path: Path) -> None:
    status, stderr = invoke(tmp_path / "missing.sock", "secret")

    assert status == 1
    assert "failed to initialize" in stderr
    assert "secret" not in stderr
