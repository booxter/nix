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

from audiobookshelf_tools.api import (
    AudiobookshelfError,
    AuthenticationRejected,
    InvalidResponse,
    UpdateFailed,
)
from audiobookshelf_tools.cli import run
from audiobookshelf_tools.reconcile import LibraryConflict, ReadinessTimeout


def oidc_settings() -> dict[str, object]:
    return {
        "authActiveAuthMethods": ["local", "openid"],
        "authOpenIDIssuerURL": "https://identity.example.test/oauth2/openid/books",
        "authOpenIDAuthorizationURL": "https://identity.example.test/authorize",
        "authOpenIDTokenURL": "https://identity.example.test/token",
        "authOpenIDUserInfoURL": "https://identity.example.test/userinfo",
        "authOpenIDJwksURL": "https://identity.example.test/jwks",
        "authOpenIDLogoutURL": None,
        "authOpenIDClientID": "books",
        "authOpenIDClientSecret": None,
        "authOpenIDTokenSigningAlgorithm": "ES256",
        "authOpenIDButtonText": "SSO",
        "authOpenIDAutoLaunch": True,
        "authOpenIDAutoRegister": True,
        "authOpenIDMatchExistingBy": "username",
        "authOpenIDMobileRedirectURIs": ["audiobookshelf://oauth"],
        "authOpenIDGroupClaim": "abs_groups",
        "authOpenIDAdvancedPermsClaim": "",
        "authOpenIDSubfolderForRedirectURLs": "",
    }


def desired_settings(*, backups: bool = True) -> dict[str, object]:
    return {
        "oidc": oidc_settings(),
        "backups": (
            {"backupSchedule": "15 4 * * *", "backupsToKeep": 2, "maxBackupSize": 1}
            if backups
            else None
        ),
        "libraries": [
            {
                "name": "Spoken books",
                "path": "/srv/media/spoken",
                "mediaType": "book",
                "provider": "audible",
                "icon": "audiobookshelf",
                "audiobooksOnly": True,
            }
        ],
    }


@dataclass
class ApiState:
    auth: object = field(default_factory=dict)
    settings: object = field(default_factory=dict)
    libraries: object = field(default_factory=list)
    get_statuses: dict[str, list[int]] = field(default_factory=dict)
    write_statuses: dict[tuple[str, str], int] = field(default_factory=dict)
    writes: list[tuple[str, str, dict[str, object]]] = field(default_factory=list)
    authorization_headers: set[str] = field(default_factory=set)

    def status(self, path: str) -> int:
        statuses = self.get_statuses.get(path, [200])
        return statuses.pop(0) if len(statuses) > 1 else statuses[0]


@contextmanager
def api_server(state: ApiState) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            self.record_authorization()
            bodies = {
                "/api/auth-settings": state.auth,
                "/api/libraries": {"libraries": state.libraries},
            }
            if path not in bodies:
                self.respond(404, {})
                return
            self.respond(state.status(path), bodies[path])

        def do_PATCH(self) -> None:
            self.write_request("PATCH")

        def do_POST(self) -> None:
            if urlsplit(self.path).path == "/api/authorize":
                self.record_authorization()
                self.respond(state.status("/api/authorize"), {"serverSettings": state.settings})
            else:
                self.write_request("POST")

        def write_request(self, method: str) -> None:
            path = urlsplit(self.path).path
            self.record_authorization()
            length = int(self.headers.get("Content-Length", "0"))
            payload = cast(dict[str, object], json.loads(self.rfile.read(length)))
            state.writes.append((method, path, payload))
            status = state.write_statuses.get((method, path), 204)
            if 200 <= status < 300:
                if path == "/api/auth-settings" and isinstance(state.auth, dict):
                    state.auth.update(payload)
                elif path == "/api/settings" and isinstance(state.settings, dict):
                    state.settings.update(payload)
            self.respond(status, {})

        def record_authorization(self) -> None:
            value = self.headers.get("Authorization")
            if value is not None:
                state.authorization_headers.add(value)

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


class ManualTime:
    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def clock(self) -> float:
        return self.now

    def sleep(self, duration: float) -> None:
        self.sleeps.append(duration)
        self.now += duration


class RecordingRestarter:
    def __init__(self) -> None:
        self.units: list[str] = []

    def try_restart(self, unit: str) -> None:
        self.units.append(unit)


def arguments(
    tmp_path: Path, base_url: str, settings: dict[str, object]
) -> tuple[list[str], dict[str, str]]:
    credentials = tmp_path / "credentials"
    credentials.mkdir()
    (credentials / "api-token").write_text("automation-token\n", encoding="utf-8")
    (credentials / "oidc-secret").write_text("client-secret\n", encoding="utf-8")
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps(settings), encoding="utf-8")
    return (
        [
            "--url",
            base_url,
            "--api-token-credential",
            "api-token",
            "--client-secret-credential",
            "oidc-secret",
            "--settings-file",
            str(settings_file),
            "--restart-unit",
            "audiobookshelf.service",
        ],
        {"CREDENTIALS_DIRECTORY": str(credentials)},
    )


def run_with_state(
    tmp_path: Path,
    state: ApiState,
    settings: dict[str, object] | None = None,
    *,
    manual: ManualTime | None = None,
) -> tuple[bool, bool, int]:
    timer = manual or ManualTime()
    with api_server(state) as base_url:
        args, environment = arguments(tmp_path, base_url, settings or desired_settings())
        return run(
            args,
            environment,
            RecordingRestarter(),
            clock=timer.clock,
            sleep=timer.sleep,
        )


def current_auth() -> dict[str, object]:
    return {**oidc_settings(), "authOpenIDClientSecret": "client-secret", "unmanaged": True}


def current_library(**changes: object) -> dict[str, object]:
    result: dict[str, object] = {
        "id": "library-id",
        "name": "Spoken books",
        "folders": [{"fullPath": "/srv/media/spoken"}],
        "mediaType": "book",
        "provider": "audible",
        "icon": "audiobookshelf",
        "settings": {"audiobooksOnly": True, "unmanaged": True},
    }
    result.update(changes)
    return result


def test_reconcile_updates_ordered_settings_and_creates_library(tmp_path: Path) -> None:
    state = ApiState()
    restarter = RecordingRestarter()
    timer = ManualTime()
    with api_server(state) as base_url:
        args, environment = arguments(tmp_path, base_url, desired_settings())
        result = run(args, environment, restarter, clock=timer.clock, sleep=timer.sleep)

    assert result == (True, True, 1)
    assert restarter.units == ["audiobookshelf.service"]
    assert [item[:2] for item in state.writes] == [
        ("PATCH", "/api/auth-settings"),
        ("PATCH", "/api/settings"),
        ("POST", "/api/libraries"),
    ]
    assert state.writes[-1][2] == {
        "name": "Spoken books",
        "folders": [{"fullPath": "/srv/media/spoken"}],
        "mediaType": "book",
        "provider": "audible",
        "icon": "audiobookshelf",
        "settings": {"audiobooksOnly": True},
    }
    assert state.authorization_headers == {"Bearer automation-token"}


def test_reconcile_is_idempotent_and_preserves_unmanaged_values(tmp_path: Path) -> None:
    state = ApiState(
        auth=current_auth(),
        settings={"backupSchedule": "15 4 * * *", "backupsToKeep": 2, "maxBackupSize": 1},
        libraries=[current_library()],
    )
    assert run_with_state(tmp_path, state) == (False, False, 0)
    assert state.writes == []


def test_reconcile_adopts_library_by_path_and_only_updates_safe_fields(tmp_path: Path) -> None:
    state = ApiState(
        auth=current_auth(),
        settings={"backupSchedule": "15 4 * * *", "backupsToKeep": 2, "maxBackupSize": 1},
        libraries=[
            current_library(
                name="Old name",
                provider="google",
                icon="database",
                settings={"audiobooksOnly": False},
            )
        ],
    )
    assert run_with_state(tmp_path, state) == (False, False, 1)
    assert state.writes == [
        (
            "PATCH",
            "/api/libraries/library-id",
            {
                "name": "Spoken books",
                "provider": "audible",
                "icon": "audiobookshelf",
                "settings": {"audiobooksOnly": True},
            },
        )
    ]


def test_reconcile_accepts_folder_path_compatibility_field(tmp_path: Path) -> None:
    library = current_library(folders=[{"path": "/srv/media/spoken"}])
    state = ApiState(auth=current_auth(), settings={}, libraries=[library])
    settings = desired_settings(backups=False)
    assert run_with_state(tmp_path, state, settings) == (False, False, 0)


@pytest.mark.parametrize(
    ("libraries", "message"),
    [
        ([current_library(folders=[{"fullPath": "/somewhere/else"}])], "different path"),
        (
            [current_library(), current_library(id="other-library")],
            "multiple Audiobookshelf libraries",
        ),
        ([current_library(mediaType="podcast")], "media type"),
    ],
)
def test_reconcile_refuses_ambiguous_or_destructive_library_adoption(
    tmp_path: Path, libraries: list[dict[str, object]], message: str
) -> None:
    state = ApiState(auth=current_auth(), settings={}, libraries=libraries)
    with pytest.raises(LibraryConflict, match=message):
        run_with_state(tmp_path, state, desired_settings(backups=False))
    assert state.writes == []


def test_reconcile_refuses_duplicate_desired_library_paths(tmp_path: Path) -> None:
    settings = desired_settings(backups=False)
    libraries = cast(list[dict[str, object]], settings["libraries"])
    libraries.append({**libraries[0], "name": "Another library"})
    state = ApiState(auth=current_auth(), settings={}, libraries=[])
    with pytest.raises(LibraryConflict, match="paths must be unique"):
        run_with_state(tmp_path, state, settings)
    assert state.writes == []


def test_reconcile_waits_for_initial_and_restarted_service(tmp_path: Path) -> None:
    state = ApiState(get_statuses={"/api/auth-settings": [503, 200, 503, 200]})
    timer = ManualTime()
    assert run_with_state(tmp_path, state, manual=timer) == (True, True, 1)
    assert timer.sleeps == [2.0, 2.0]


def test_reconcile_times_out_with_last_status(tmp_path: Path) -> None:
    state = ApiState(get_statuses={"/api/auth-settings": [503]})
    timer = ManualTime()
    with api_server(state) as base_url:
        args, environment = arguments(tmp_path, base_url, desired_settings())
        args.extend(["--wait-seconds", "2"])
        with pytest.raises(ReadinessTimeout, match="503"):
            run(
                args,
                environment,
                RecordingRestarter(),
                clock=timer.clock,
                sleep=timer.sleep,
            )
    assert timer.sleeps == [2.0]


def test_reconcile_rejects_bad_automation_credential(tmp_path: Path) -> None:
    state = ApiState(get_statuses={"/api/auth-settings": [401]})
    with pytest.raises(AuthenticationRejected):
        run_with_state(tmp_path, state)


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("auth", [], "auth settings"),
        ("settings", [], "settings"),
        ("libraries", {}, "libraries"),
    ],
)
def test_reconcile_rejects_invalid_api_models(
    tmp_path: Path, field: str, value: object, message: str
) -> None:
    state = ApiState(auth=current_auth(), settings={}, libraries=[])
    setattr(state, field, value)
    with pytest.raises(InvalidResponse, match=message):
        run_with_state(tmp_path, state)


@pytest.mark.parametrize(
    ("state", "message"),
    [
        (
            ApiState(write_statuses={("PATCH", "/api/auth-settings"): 400}),
            "OIDC settings",
        ),
        (
            ApiState(
                auth=current_auth(),
                write_statuses={("PATCH", "/api/settings"): 500},
            ),
            "backup settings",
        ),
        (
            ApiState(
                auth=current_auth(),
                settings={},
                write_statuses={("POST", "/api/libraries"): 409},
            ),
            "library",
        ),
        (
            ApiState(
                auth=current_auth(),
                settings={},
                libraries=[current_library(name="Old")],
                write_statuses={("PATCH", "/api/libraries/library-id"): 500},
            ),
            "library",
        ),
    ],
)
def test_reconcile_reports_write_failures(tmp_path: Path, state: ApiState, message: str) -> None:
    with pytest.raises(UpdateFailed, match=message):
        run_with_state(tmp_path, state)


def test_reconcile_reports_unreachable_api(tmp_path: Path) -> None:
    with api_server(ApiState()) as base_url:
        args, environment = arguments(tmp_path, base_url, desired_settings())
    args.extend(["--wait-seconds", "0"])
    with pytest.raises(ReadinessTimeout, match="unreachable"):
        run(
            args,
            environment,
            RecordingRestarter(),
            clock=lambda: 0.0,
            sleep=lambda _: None,
        )


def test_reconcile_requires_systemd_credentials_directory(tmp_path: Path) -> None:
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps(desired_settings()), encoding="utf-8")
    with pytest.raises(AudiobookshelfError, match="CREDENTIALS_DIRECTORY"):
        run(
            [
                "--url",
                "http://127.0.0.1:1",
                "--api-token-credential",
                "api-token",
                "--client-secret-credential",
                "oidc-secret",
                "--settings-file",
                str(settings_file),
                "--restart-unit",
                "audiobookshelf.service",
            ],
            {},
            RecordingRestarter(),
            clock=lambda: 0.0,
            sleep=lambda _: None,
        )
