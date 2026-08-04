from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast
from urllib.parse import urlsplit

import httpx
import pytest

from pinepods_tools.api import PinepodsApi, PinepodsApiError
from pinepods_tools.cli import run_backup, run_bootstrap, run_database_password
from pinepods_tools.models import CreateAdminRequest
from pinepods_tools.service import PinepodsServiceError, bootstrap_admin, native_backup

Response = tuple[int, object]


@dataclass
class ApiState:
    self_service: list[Response] = field(
        default_factory=lambda: [(200, {"first_admin_created": False})]
    )
    create_response: Response = (200, {"user_id": 42})
    start_response: Response = (200, {"task_id": "task-1"})
    task_responses: list[Response] = field(default_factory=lambda: [(200, {"status": "SUCCESS"})])
    files_response: Response = (200, {"backup_files": []})
    created_admins: list[dict[str, object]] = field(default_factory=list)
    deleted_backups: list[str] = field(default_factory=list)
    api_keys: set[str] = field(default_factory=set)

    @staticmethod
    def next_response(responses: list[Response]) -> Response:
        return responses.pop(0) if len(responses) > 1 else responses[0]


@contextmanager
def api_server(state: ApiState) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            if path == "/api/data/self_service_status":
                response = state.next_response(state.self_service)
            elif path == "/api/tasks/task-1":
                response = state.next_response(state.task_responses)
            else:
                response = (404, {"error": "not found"})
            self.respond(*response)

        def do_POST(self) -> None:
            api_key = self.headers.get("Api-Key")
            if api_key is not None:
                state.api_keys.add(api_key)
            length = int(self.headers.get("Content-Length", "0"))
            payload = cast(dict[str, object], json.loads(self.rfile.read(length) or b"{}"))
            path = urlsplit(self.path).path
            if path == "/api/data/create_first":
                state.created_admins.append(payload)
                response = state.create_response
            elif path == "/api/data/manual_backup_to_directory":
                response = state.start_response
            elif path == "/api/data/list_backup_files":
                response = state.files_response
            elif path == "/api/data/delete_backup_file":
                state.deleted_backups.append(str(payload["backup_filename"]))
                response = (204, {})
            else:
                response = (404, {"error": "not found"})
            self.respond(*response)

        def respond(self, status: int, body: object) -> None:
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


class InMemoryDatabase:
    def __init__(self, api_key: str | None = "admin-key") -> None:
        self.api_key = api_key
        self.passwords: dict[str, str] = {}

    def admin_api_key(self) -> str | None:
        return self.api_key

    def set_role_password(self, role: str, password: str) -> None:
        self.passwords[role] = password


def api(base_url: str) -> tuple[httpx.Client, PinepodsApi]:
    client = httpx.Client(base_url=base_url)
    return client, PinepodsApi(client)


def test_bootstrap_waits_then_creates_typed_admin(tmp_path: Path) -> None:
    state = ApiState(self_service=[(503, {}), (200, {"first_admin_created": False})])
    email = tmp_path / "email"
    password = tmp_path / "password"
    email.write_text("admin@example.test\n", encoding="utf-8")
    password.write_text("secret\n", encoding="utf-8")
    sleeps: list[float] = []
    with api_server(state) as base_url:
        user_id = run_bootstrap(
            [
                "--url",
                base_url,
                "--username",
                "admin",
                "--full-name",
                "Admin User",
                "--email-file",
                str(email),
                "--password-file",
                str(password),
            ],
            sleep=sleeps.append,
        )

    assert user_id == 42
    assert sleeps == [2.0]
    assert state.created_admins == [
        {
            "username": "admin",
            "fullname": "Admin User",
            "email": "admin@example.test",
            "password": "secret",
        }
    ]


def test_bootstrap_is_idempotent_when_admin_exists() -> None:
    state = ApiState(self_service=[(200, {"first_admin_created": True})])
    with api_server(state) as base_url:
        client, pinepods = api(base_url)
        with client:
            user_id = bootstrap_admin(
                pinepods,
                CreateAdminRequest(
                    username="admin",
                    fullname="Admin User",
                    email="admin@example.test",
                    password="secret",
                ),
                attempts=1,
                interval=2,
                sleep=lambda _: None,
            )
    assert user_id is None
    assert state.created_admins == []


def test_bootstrap_times_out_when_setup_api_stays_unavailable() -> None:
    state = ApiState(self_service=[(503, {})])
    with api_server(state) as base_url:
        client, pinepods = api(base_url)
        with client:
            with pytest.raises(PinepodsServiceError, match="Timed out"):
                bootstrap_admin(
                    pinepods,
                    CreateAdminRequest(
                        username="admin",
                        fullname="Admin User",
                        email="admin@example.test",
                        password="secret",
                    ),
                    attempts=2,
                    interval=2,
                    sleep=lambda _: None,
                )


def test_api_rejects_invalid_self_service_state() -> None:
    state = ApiState(self_service=[(200, {"first_admin_created": "not-a-boolean"})])
    with api_server(state) as base_url:
        client, pinepods = api(base_url)
        with client:
            with pytest.raises(PinepodsApiError, match="invalid self-service"):
                pinepods.self_service_status()


def backup_files(count: int) -> list[dict[str, str]]:
    return [{"filename": f"backup-{index}.zip"} for index in range(count)]


def test_native_backup_waits_and_prunes_files_after_retention() -> None:
    state = ApiState(
        task_responses=[
            (200, {"status": "PENDING"}),
            (200, {"status": "DOWNLOADING"}),
            (200, {"status": "SUCCESS"}),
        ],
        files_response=(200, {"backup_files": backup_files(9)}),
    )
    sleeps: list[float] = []
    database = InMemoryDatabase()
    with api_server(state) as base_url:
        deleted = run_backup(
            ["--url", base_url, "--database", "pinepods", "--keep", "7"],
            lambda _: database,
            sleep=sleeps.append,
        )

    assert deleted == ("backup-7.zip", "backup-8.zip")
    assert state.deleted_backups == ["backup-7.zip", "backup-8.zip"]
    assert state.api_keys == {"admin-key"}
    assert sleeps == [2.0, 2.0]


@pytest.mark.parametrize(
    ("status", "message"),
    [("FAILED", "failed"), ("SURPRISE", "unknown")],
)
def test_native_backup_rejects_failed_or_unknown_task(status: str, message: str) -> None:
    state = ApiState(task_responses=[(200, {"status": status})])
    with api_server(state) as base_url:
        client, pinepods = api(base_url)
        with client:
            with pytest.raises(PinepodsServiceError, match=message):
                native_backup(
                    pinepods,
                    InMemoryDatabase(),
                    keep=7,
                    attempts=1,
                    interval=2,
                    sleep=lambda _: None,
                )


def test_native_backup_times_out_and_requires_admin_key() -> None:
    state = ApiState(task_responses=[(200, {"status": "PENDING"})])
    with api_server(state) as base_url:
        client, pinepods = api(base_url)
        with client:
            with pytest.raises(PinepodsServiceError, match="timed out"):
                native_backup(
                    pinepods,
                    InMemoryDatabase(),
                    keep=7,
                    attempts=1,
                    interval=2,
                    sleep=lambda _: None,
                )
            with pytest.raises(PinepodsServiceError, match="no API key"):
                native_backup(
                    pinepods,
                    InMemoryDatabase(api_key=None),
                    keep=7,
                    attempts=1,
                    interval=2,
                    sleep=lambda _: None,
                )


def test_database_password_reads_secret_without_newline(tmp_path: Path) -> None:
    password = tmp_path / "password"
    password.write_text("database-secret\n", encoding="utf-8")
    database = InMemoryDatabase()

    run_database_password(
        ["--database", "pinepods", "--role", "pinepods", "--password-file", str(password)],
        lambda _: database,
    )

    assert database.passwords == {"pinepods": "database-secret"}
