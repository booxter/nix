from __future__ import annotations

import os
from pathlib import Path

import psycopg

from postgresql_role_password.cli import run
from postgresql_role_password.role import read_secret


def test_reads_secret_without_line_ending(tmp_path: Path) -> None:
    secret = tmp_path / "password"
    secret.write_text("database-secret\r\n", encoding="utf-8")

    assert read_secret(secret) == "database-secret"


def test_sets_password_for_quoted_role_name(tmp_path: Path) -> None:
    database = os.environ["PGDATABASE"]
    role = 'service-role"quoted'
    secret = tmp_path / "password"
    secret.write_text("database-secret\n", encoding="utf-8")

    with psycopg.connect(dbname=database) as connection:
        connection.execute(
            psycopg.sql.SQL("CREATE ROLE {} LOGIN").format(psycopg.sql.Identifier(role))
        )

    run(
        [
            "--database",
            database,
            "--role",
            role,
            "--password-file",
            str(secret),
        ]
    )

    with psycopg.connect(dbname=database) as connection:
        password_hash = connection.execute(
            "SELECT rolpassword FROM pg_authid WHERE rolname = %s",
            (role,),
        ).fetchone()

    assert password_hash is not None
    assert isinstance(password_hash[0], str)
    assert password_hash[0].startswith("SCRAM-SHA-256$")
