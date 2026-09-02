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
from pinepods_tools.cli import run_bootstrap
from pinepods_tools.models import CreateAdminRequest
from pinepods_tools.service import PinepodsServiceError, bootstrap_admin

Response = tuple[int, object]


@dataclass
class ApiState:
    self_service: list[Response] = field(
        default_factory=lambda: [(200, {"first_admin_created": False})]
    )
    create_response: Response = (200, {"user_id": 42})
    created_admins: list[dict[str, object]] = field(default_factory=list)

    def next_status(self) -> Response:
        return self.self_service.pop(0) if len(self.self_service) > 1 else self.self_service[0]


@contextmanager
def api_server(state: ApiState) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            response = (
                state.next_status()
                if urlsplit(self.path).path == "/api/data/self_service_status"
                else (404, {"error": "not found"})
            )
            self.respond(*response)

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            payload = cast(dict[str, object], json.loads(self.rfile.read(length) or b"{}"))
            if urlsplit(self.path).path == "/api/data/create_first":
                state.created_admins.append(payload)
                response = state.create_response
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
        with client, pytest.raises(PinepodsServiceError, match="Timed out"):
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
    state = ApiState(self_service=[(200, {"first_admin_created": "invalid"})])
    with api_server(state) as base_url:
        client, pinepods = api(base_url)
        with client, pytest.raises(PinepodsApiError, match="invalid self-service"):
            pinepods.self_service_status()
