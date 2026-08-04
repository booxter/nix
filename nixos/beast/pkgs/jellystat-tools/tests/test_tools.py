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

import pytest

from jellystat_tools.cli import run_backup, run_bootstrap
from jellystat_tools.service import JellystatServiceError

Response = tuple[int, object]


@dataclass
class ApiState:
    configuration: list[Response] = field(default_factory=lambda: [(200, {"state": 0})])
    create_user_response: Response = (200, {"token": "created-token"})
    login_response: Response = (200, {"token": "login-token"})
    set_configuration: list[Response] = field(default_factory=lambda: [(200, {})])
    library_response: Response = (200, [])
    backup_dir: Path | None = None
    create_backup_file: bool = True
    payloads: dict[str, list[dict[str, object]]] = field(default_factory=dict)
    authorizations: dict[str, list[str | None]] = field(default_factory=dict)
    requests: list[str] = field(default_factory=list)

    @staticmethod
    def next_response(responses: list[Response]) -> Response:
        return responses.pop(0) if len(responses) > 1 else responses[0]

    def record(
        self,
        path: str,
        authorization: str | None,
        payload: dict[str, object] | None = None,
    ) -> None:
        self.requests.append(path)
        self.authorizations.setdefault(path, []).append(authorization)
        if payload is not None:
            self.payloads.setdefault(path, []).append(payload)


@contextmanager
def api_server(state: ApiState) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            state.record(path, self.headers.get("Authorization"))
            if path == "/auth/isConfigured":
                response = state.next_response(state.configuration)
            elif path == "/stats/getLibraryMetadata":
                response = state.library_response
            elif path == "/sync/beginSync":
                response = (200, {})
            elif path == "/backup/beginBackup":
                if state.create_backup_file and state.backup_dir is not None:
                    (state.backup_dir / "backup_new.json").write_text("{}", encoding="utf-8")
                response = (200, {})
            else:
                response = (404, {"error": "not found"})
            self.respond(*response)

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            payload = cast(
                dict[str, object],
                json.loads(self.rfile.read(length) or b"{}"),
            )
            path = urlsplit(self.path).path
            state.record(path, self.headers.get("Authorization"), payload)
            if path == "/auth/createuser":
                response = state.create_user_response
            elif path == "/auth/login":
                response = state.login_response
            elif path == "/api/setconfig":
                response = state.next_response(state.set_configuration)
            elif path in ("/auth/configSetup", "/api/setRequireLogin"):
                response = (200, {})
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


def api_key_file(tmp_path: Path) -> Path:
    path = tmp_path / "jellyfin-api-key"
    path.write_text("jellyfin-key\n", encoding="utf-8")
    return path


def bootstrap_arguments(base_url: str, api_key: Path) -> list[str]:
    return [
        "--url",
        base_url,
        "--jellyfin-url",
        "https://jellyfin.example.test",
        "--jellyfin-api-key-file",
        str(api_key),
    ]


def test_bootstrap_configures_connection_and_starts_initial_sync(tmp_path: Path) -> None:
    state = ApiState(
        set_configuration=[(503, {}), (200, {})],
        library_response=(200, []),
    )
    sleeps: list[float] = []
    with api_server(state) as base_url:
        reconciled = run_bootstrap(
            bootstrap_arguments(base_url, api_key_file(tmp_path)),
            sleep=sleeps.append,
        )

    configuration = {
        "JF_HOST": "https://jellyfin.example.test",
        "JF_API_KEY": "jellyfin-key",
    }
    assert reconciled is True
    assert state.payloads["/auth/createuser"] == [
        {"username": "oauth2-proxy", "password": "disabled"}
    ]
    assert state.payloads["/auth/configSetup"] == [configuration]
    assert state.payloads["/api/setconfig"] == [configuration, configuration]
    assert state.payloads["/api/setRequireLogin"] == [{"REQUIRE_LOGIN": False}]
    assert state.requests.count("/sync/beginSync") == 1
    assert state.authorizations["/api/setconfig"] == [
        "Bearer created-token",
        "Bearer created-token",
    ]
    assert sleeps == [2.0]


def test_bootstrap_leaves_existing_login_unchanged_without_token(tmp_path: Path) -> None:
    state = ApiState(
        configuration=[(200, {"state": 2})],
        login_response=(401, {"error": "disabled"}),
    )
    with api_server(state) as base_url:
        reconciled = run_bootstrap(
            bootstrap_arguments(base_url, api_key_file(tmp_path)),
            sleep=lambda _: None,
        )

    assert reconciled is False
    assert "/auth/createuser" not in state.requests
    assert "/api/setconfig" not in state.requests


def test_bootstrap_reconciles_existing_configuration_without_resync(
    tmp_path: Path,
) -> None:
    state = ApiState(
        configuration=[(200, {"state": 2})],
        library_response=(200, [{"name": "Movies"}]),
    )
    with api_server(state) as base_url:
        reconciled = run_bootstrap(
            bootstrap_arguments(base_url, api_key_file(tmp_path)),
            sleep=lambda _: None,
        )

    assert reconciled is True
    assert "/auth/createuser" not in state.requests
    assert state.authorizations["/api/setconfig"] == ["Bearer login-token"]
    assert "/sync/beginSync" not in state.requests


def test_bootstrap_times_out_when_api_is_unavailable(tmp_path: Path) -> None:
    state = ApiState(configuration=[(503, {})])
    sleeps: list[float] = []
    with api_server(state) as base_url:
        with pytest.raises(JellystatServiceError, match="setup API"):
            run_bootstrap(
                [
                    *bootstrap_arguments(base_url, api_key_file(tmp_path)),
                    "--attempts",
                    "2",
                ],
                sleep=sleeps.append,
            )

    assert sleeps == [2.0]


def test_backup_waits_for_configuration_and_detects_new_file(tmp_path: Path) -> None:
    old_backup = tmp_path / "backup_old.json"
    old_backup.write_text("{}", encoding="utf-8")
    state = ApiState(
        configuration=[(200, {"state": 1}), (200, {"state": 2})],
        backup_dir=tmp_path,
    )
    sleeps: list[float] = []
    with api_server(state) as base_url:
        created = run_backup(
            ["--url", base_url, "--backup-dir", str(tmp_path)],
            sleep=sleeps.append,
        )

    assert created == tmp_path / "backup_new.json"
    assert old_backup.exists()
    assert state.authorizations["/backup/beginBackup"] == ["Bearer login-token"]
    assert sleeps == [2.0]


def test_backup_requires_token_and_new_file(tmp_path: Path) -> None:
    no_token = ApiState(
        configuration=[(200, {"state": 2})],
        login_response=(200, {}),
        backup_dir=tmp_path,
    )
    with api_server(no_token) as base_url:
        with pytest.raises(JellystatServiceError, match="backup token"):
            run_backup(
                ["--url", base_url, "--backup-dir", str(tmp_path)],
                sleep=lambda _: None,
            )

    no_file = ApiState(
        configuration=[(200, {"state": 2})],
        backup_dir=tmp_path,
        create_backup_file=False,
    )
    with api_server(no_file) as base_url:
        with pytest.raises(JellystatServiceError, match="did not create"):
            run_backup(
                ["--url", base_url, "--backup-dir", str(tmp_path)],
                sleep=lambda _: None,
            )
