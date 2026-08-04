from __future__ import annotations

import argparse
import json
import sqlite3
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def option(database: Path, name: str) -> str | None:
    try:
        with sqlite3.connect(database) as connection:
            row = connection.execute("SELECT value FROM options WHERE name = ?", (name,)).fetchone()
    except sqlite3.Error:
        return None
    return None if row is None else str(row[0])


class Server(ThreadingHTTPServer):
    database: Path
    invalid_status: bool
    reject_password: bool


class Handler(BaseHTTPRequestHandler):
    @property
    def typed_server(self) -> Server:
        assert isinstance(self.server, Server)
        return self.server

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/api/setup/status":
            self.send_error(404)
            return
        payload = (
            {}
            if self.typed_server.invalid_status
            else {"isInitialized": option(self.typed_server.database, "initialized") == "true"}
        )
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/api/setup/new-document":
            with sqlite3.connect(self.typed_server.database) as connection:
                connection.execute(
                    "CREATE TABLE IF NOT EXISTS options "
                    "(name TEXT PRIMARY KEY, value TEXT NOT NULL)"
                )
                connection.executemany(
                    "INSERT OR REPLACE INTO options(name, value) VALUES (?, ?)",
                    [
                        ("initialized", "true"),
                        ("passwordVerificationHash", ""),
                        ("mfaEnabled", "false"),
                        ("mfaMethod", "local"),
                    ],
                )
            self.send_response(204)
            self.end_headers()
            return

        if self.path == "/set-password":
            length = int(self.headers.get("Content-Length", "0"))
            form = urllib.parse.parse_qs(self.rfile.read(length).decode())
            passwords_match = form.get("password1") == form.get("password2") and bool(
                form.get("password1", [""])[0]
            )
            if self.typed_server.reject_password or not passwords_match:
                self.send_error(500)
                return
            with sqlite3.connect(self.typed_server.database) as connection:
                connection.execute(
                    "UPDATE options SET value = 'configured' "
                    "WHERE name = 'passwordVerificationHash'"
                )
            self.send_response(302)
            self.send_header("Location", "/login")
            self.end_headers()
            return

        self.send_error(404)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--invalid-status", action="store_true")
    parser.add_argument("--reject-password", action="store_true")
    parser.add_argument("--exit-immediately", action="store_true")
    options = parser.parse_args()
    if options.exit_immediately:
        raise SystemExit(17)

    server = Server(("127.0.0.1", options.port), Handler)
    server.database = options.database
    server.invalid_status = options.invalid_status
    server.reject_password = options.reject_password
    server.serve_forever()


if __name__ == "__main__":
    main()
