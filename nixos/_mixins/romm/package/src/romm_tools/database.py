from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from pydantic import SecretStr
from sqlalchemy import URL, create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.pool import NullPool

DATABASE = "romm"
DATABASE_USER = "romm"
DATABASE_HOST = "localhost"
PASSWORD_ENVIRONMENT = "DB_PASSWD"


class Error(RuntimeError):
    pass


def engine(socket: Path, user: str, password: SecretStr | None = None) -> Engine:
    return create_engine(
        URL.create(
            "mariadb+mariadbconnector",
            username=user,
            password=None if password is None else password.get_secret_value(),
            database=None if user == "root" else DATABASE,
            query={"unix_socket": str(socket)},
        ),
        isolation_level="AUTOCOMMIT",
        hide_parameters=True,
        poolclass=NullPool,
    )


def initialize(socket: Path, password: SecretStr) -> None:
    try:
        with engine(socket, "root").connect() as connection:
            connection.execute(
                text(
                    f"CREATE DATABASE IF NOT EXISTS {DATABASE} "
                    "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                )
            )
            connection.execute(
                text(
                    f"CREATE USER IF NOT EXISTS '{DATABASE_USER}'@'{DATABASE_HOST}' "
                    "IDENTIFIED BY :password"
                ),
                {"password": password.get_secret_value()},
            )
            connection.execute(
                text(f"ALTER USER '{DATABASE_USER}'@'{DATABASE_HOST}' IDENTIFIED BY :password"),
                {"password": password.get_secret_value()},
            )
            connection.execute(
                text(f"GRANT ALL PRIVILEGES ON {DATABASE}.* TO '{DATABASE_USER}'@'{DATABASE_HOST}'")
            )

        with engine(socket, DATABASE_USER, password).connect() as connection:
            row = connection.execute(text("SELECT DATABASE()")).one()
        if tuple(row) != (DATABASE,):
            raise Error("RomM database account verification failed")
    except SQLAlchemyError as error:
        raise Error(f"failed to initialize the RomM database: {error}") from error


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description="Initialize the RomM MariaDB account")
    argument_parser.add_argument(
        "--socket",
        type=Path,
        default=Path("/run/mysqld/mysqld.sock"),
    )
    return argument_parser


def run(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    stderr: TextIO,
) -> int:
    options = parser().parse_args(arguments)
    try:
        password = SecretStr(environment[PASSWORD_ENVIRONMENT])
        if not password.get_secret_value():
            raise Error("RomM database password is empty")
        initialize(options.socket, password)
    except KeyError:
        print(
            f"romm-db-init: missing database password environment variable {PASSWORD_ENVIRONMENT}",
            file=stderr,
        )
        return 1
    except Error as error:
        print(f"romm-db-init: {error}", file=stderr)
        return 1
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], os.environ, sys.stderr))
