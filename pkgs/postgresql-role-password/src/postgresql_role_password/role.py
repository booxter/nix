from __future__ import annotations

from pathlib import Path

import psycopg
from psycopg import sql


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def set_role_password(database: str, role: str, password: str) -> None:
    statement = sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(
        sql.Identifier(role),
        sql.Literal(password),
    )
    with psycopg.connect(dbname=database) as connection:
        connection.execute(statement)
