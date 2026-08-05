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
from audiobookshelf_tools.cli import run_backup, run_oidc
from audiobookshelf_tools.models import BackupSettings, OidcSettings
from audiobookshelf_tools.reconcile import ReadinessTimeout


def oidc_settings() -> OidcSettings:
    return OidcSettings.model_validate(
        {
            "authActiveAuthMethods": ["local", "openid"],
            "authOpenIDIssuerURL": "https://books.example.test",
            "authOpenIDAuthorizationURL": "https://sso.example.test/authorize",
            "authOpenIDTokenURL": "https://sso.example.test/token",
            "authOpenIDUserInfoURL": "https://sso.example.test/userinfo",
            "authOpenIDJwksURL": "https://sso.example.test/jwks",
            "authOpenIDLogoutURL": None,
            "authOpenIDClientID": "audiobookshelf",
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
    )


def backup_settings() -> BackupSettings:
    return BackupSettings.model_validate(
        {"backupSchedule": "15 4 * * *", "backupsToKeep": 2, "maxBackupSize": 1}
    )


def write_model(path: Path, model: OidcSettings | BackupSettings) -> None:
    path.write_text(model.model_dump_json(by_alias=True), encoding="utf-8")


@dataclass
class ApiState:
    current_auth: object
    auth_statuses: list[int] = field(default_factory=lambda: [200])
    auth_patch_statuses: list[int] = field(default_factory=lambda: [204])
    backup_patch_statuses: list[int] = field(default_factory=lambda: [204])
    auth_patches: list[dict[str, object]] = field(default_factory=list)
    backup_patches: list[dict[str, object]] = field(default_factory=list)
    authorization_headers: set[str] = field(default_factory=set)

    @staticmethod
    def next_status(statuses: list[int]) -> int:
        return statuses.pop(0) if len(statuses) > 1 else statuses[0]


@contextmanager
def api_server(state: ApiState) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            authorization = self.headers.get("Authorization")
            if authorization is not None:
                state.authorization_headers.add(authorization)
            if urlsplit(self.path).path != "/api/auth-settings":
                self.send_error(404)
                return
            status = state.next_status(state.auth_statuses)
            self.respond(status, state.current_auth)

        def do_PATCH(self) -> None:
            authorization = self.headers.get("Authorization")
            if authorization is not None:
                state.authorization_headers.add(authorization)
            length = int(self.headers.get("Content-Length", "0"))
            payload = cast(dict[str, object], json.loads(self.rfile.read(length)))
            path = urlsplit(self.path).path
            if path == "/api/auth-settings":
                state.auth_patches.append(payload)
                status = state.next_status(state.auth_patch_statuses)
                if 200 <= status < 300 and isinstance(state.current_auth, dict):
                    state.current_auth.update(payload)
            elif path == "/api/settings":
                state.backup_patches.append(payload)
                status = state.next_status(state.backup_patch_statuses)
            else:
                status = 404
            self.respond(status, {})

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


def oidc_arguments(tmp_path: Path, base_url: str) -> list[str]:
    token = tmp_path / "token"
    secret = tmp_path / "secret"
    settings = tmp_path / "oidc.json"
    token.write_text("api-token\n", encoding="utf-8")
    secret.write_text("client-secret\n", encoding="utf-8")
    write_model(settings, oidc_settings())
    return [
        "--url",
        base_url,
        "--api-token-file",
        str(token),
        "--client-secret-file",
        str(secret),
        "--settings-file",
        str(settings),
        "--restart-unit",
        "audiobookshelf.service",
    ]


def test_oidc_waits_updates_and_restarts_changed_service(tmp_path: Path) -> None:
    state = ApiState(current_auth={"unmanaged": True}, auth_statuses=[503, 200])
    manual = ManualTime()
    restarter = RecordingRestarter()
    with api_server(state) as base_url:
        changed = run_oidc(
            oidc_arguments(tmp_path, base_url),
            restarter,
            clock=manual.clock,
            sleep=manual.sleep,
        )

    assert changed
    assert manual.sleeps == [2.0]
    assert restarter.units == ["audiobookshelf.service"]
    assert len(state.auth_patches) == 1
    assert state.auth_patches[0]["authOpenIDClientSecret"] == "client-secret"
    assert state.authorization_headers == {"Bearer api-token"}


def test_oidc_skips_patch_and_restart_when_desired_subset_matches(tmp_path: Path) -> None:
    desired = (
        oidc_settings().with_client_secret("client-secret").model_dump(mode="json", by_alias=True)
    )
    state = ApiState(current_auth={**desired, "unmanaged": True})
    manual = ManualTime()
    restarter = RecordingRestarter()
    with api_server(state) as base_url:
        changed = run_oidc(
            oidc_arguments(tmp_path, base_url),
            restarter,
            clock=manual.clock,
            sleep=manual.sleep,
        )

    assert not changed
    assert state.auth_patches == []
    assert restarter.units == []


def test_oidc_rejects_bad_api_token_without_waiting(tmp_path: Path) -> None:
    state = ApiState(current_auth={}, auth_statuses=[401])
    manual = ManualTime()
    with api_server(state) as base_url:
        with pytest.raises(AuthenticationRejected):
            run_oidc(
                oidc_arguments(tmp_path, base_url),
                RecordingRestarter(),
                clock=manual.clock,
                sleep=manual.sleep,
            )
    assert manual.sleeps == []


def test_oidc_times_out_with_last_http_status(tmp_path: Path) -> None:
    state = ApiState(current_auth={}, auth_statuses=[503])
    manual = ManualTime()
    with api_server(state) as base_url:
        arguments = oidc_arguments(tmp_path, base_url) + ["--wait-seconds", "2"]
        with pytest.raises(ReadinessTimeout, match="503"):
            run_oidc(
                arguments,
                RecordingRestarter(),
                clock=manual.clock,
                sleep=manual.sleep,
            )
    assert manual.sleeps == [2.0]


def test_oidc_rejects_invalid_auth_response(tmp_path: Path) -> None:
    state = ApiState(current_auth=[])
    manual = ManualTime()
    with api_server(state) as base_url:
        with pytest.raises(InvalidResponse):
            run_oidc(
                oidc_arguments(tmp_path, base_url),
                RecordingRestarter(),
                clock=manual.clock,
                sleep=manual.sleep,
            )


def backup_arguments(tmp_path: Path, base_url: str, *, retry_count: int = 2) -> list[str]:
    token = tmp_path / "token"
    settings = tmp_path / "backup.json"
    token.write_text("api-token\n", encoding="utf-8")
    write_model(settings, backup_settings())
    return [
        "--url",
        base_url,
        "--api-token-file",
        str(token),
        "--settings-file",
        str(settings),
        "--retry-count",
        str(retry_count),
        "--retry-delay",
        "2",
    ]


def test_backup_settings_retry_transient_failure(tmp_path: Path) -> None:
    state = ApiState(current_auth={}, backup_patch_statuses=[503, 204])
    manual = ManualTime()
    with api_server(state) as base_url:
        run_backup(backup_arguments(tmp_path, base_url), {}, sleep=manual.sleep)

    assert manual.sleeps == [2.0]
    assert state.backup_patches[-1] == {
        "backupSchedule": "15 4 * * *",
        "backupsToKeep": 2,
        "maxBackupSize": 1,
    }


def test_backup_settings_do_not_retry_permanent_failure(tmp_path: Path) -> None:
    state = ApiState(current_auth={}, backup_patch_statuses=[400])
    manual = ManualTime()
    with api_server(state) as base_url:
        with pytest.raises(UpdateFailed):
            run_backup(backup_arguments(tmp_path, base_url), {}, sleep=manual.sleep)
    assert manual.sleeps == []


def test_backup_reports_unreachable_api(tmp_path: Path) -> None:
    with api_server(ApiState(current_auth={})) as base_url:
        unavailable_url = base_url

    with pytest.raises(UpdateFailed) as raised:
        run_backup(
            backup_arguments(tmp_path, unavailable_url, retry_count=0),
            {},
            sleep=lambda _: None,
        )

    assert raised.value.status_code is None


def test_backup_resolves_systemd_credential_name(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    credentials.mkdir()
    (credentials / "api-token").write_text("api-token\n", encoding="utf-8")
    settings = tmp_path / "backup.json"
    write_model(settings, backup_settings())
    state = ApiState(current_auth={})
    with api_server(state) as base_url:
        run_backup(
            [
                "--url",
                base_url,
                "--credential-name",
                "api-token",
                "--settings-file",
                str(settings),
            ],
            {"CREDENTIALS_DIRECTORY": str(credentials)},
            sleep=lambda _: None,
        )

    assert state.authorization_headers == {"Bearer api-token"}


def test_backup_requires_systemd_credentials_directory(tmp_path: Path) -> None:
    settings = tmp_path / "backup.json"
    write_model(settings, backup_settings())

    with pytest.raises(AudiobookshelfError, match="CREDENTIALS_DIRECTORY"):
        run_backup(
            [
                "--url",
                "http://127.0.0.1:1",
                "--credential-name",
                "api-token",
                "--settings-file",
                str(settings),
            ],
            {},
            sleep=lambda _: None,
        )
