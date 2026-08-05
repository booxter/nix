from __future__ import annotations

from typing import Protocol

import psycopg
from psycopg.rows import scalar_row


class Database(Protocol):
    def admin_api_key(self) -> str | None: ...


class PsycopgDatabase:
    def __init__(self, database: str) -> None:
        self.database = database

    def admin_api_key(self) -> str | None:
        query = """
            SELECT a.apikey
              FROM "APIKeys" a
              JOIN "Users" u ON u.userid = a.userid
             WHERE u.isadmin = true
               AND u.username <> 'background_tasks'
             ORDER BY u.userid, a.apikeyid
             LIMIT 1
        """
        with psycopg.connect(dbname=self.database, row_factory=scalar_row) as connection:
            value = connection.execute(query).fetchone()
        return value if isinstance(value, str) and value else None
