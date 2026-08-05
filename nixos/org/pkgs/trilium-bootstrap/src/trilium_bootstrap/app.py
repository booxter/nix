from __future__ import annotations

import contextlib
import sqlite3
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

MAX_RESPONSE_BYTES = 1024 * 1024


class Error(RuntimeError):
    pass


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    database: Path
    base_url: str
    password_file: Path
    server_command: tuple[str, ...] = Field(min_length=1)
    startup_timeout_seconds: float = Field(default=120, gt=0)
    poll_seconds: float = Field(default=1, gt=0)

    @field_validator("base_url")
    @classmethod
    def validate_base_url(cls, value: str) -> str:
        normalized = value.rstrip("/")
        parsed = urllib.parse.urlparse(normalized)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("base_url must be an HTTP(S) URL")
        return normalized


class SetupStatus(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    initialized: bool = Field(alias="isInitialized")


@dataclass(frozen=True)
class DatabaseState:
    initialized: bool
    password_set: bool


@dataclass(frozen=True)
class TriliumDatabase:
    path: Path

    def state(self) -> DatabaseState:
        if not self.path.is_file():
            return DatabaseState(initialized=False, password_set=False)
        try:
            with contextlib.closing(sqlite3.connect(self.path)) as connection:
                initialized = self._option(connection, "initialized") == "true"
                password_set = bool(self._option(connection, "passwordVerificationHash"))
        except sqlite3.Error:
            return DatabaseState(initialized=False, password_set=False)
        return DatabaseState(initialized=initialized, password_set=password_set)

    @staticmethod
    def _option(connection: sqlite3.Connection, name: str) -> str | None:
        row = connection.execute("SELECT value FROM options WHERE name = ?", (name,)).fetchone()
        return None if row is None else str(row[0])

    def configure_mfa(self) -> None:
        try:
            with contextlib.closing(sqlite3.connect(self.path)) as connection:
                with connection:
                    connection.execute("BEGIN IMMEDIATE")
                    desired = {"mfaEnabled": "true", "mfaMethod": "oauth"}
                    for name, value in desired.items():
                        cursor = connection.execute(
                            "UPDATE options SET value = ? WHERE name = ?",
                            (value, name),
                        )
                        if cursor.rowcount != 1:
                            raise Error(f"Trilium database is missing the {name} option")
        except sqlite3.Error as error:
            raise Error(f"failed to configure Trilium MFA: {error}") from error

        try:
            with contextlib.closing(sqlite3.connect(self.path)) as connection:
                if self._option(connection, "mfaEnabled") != "true":
                    raise Error("Trilium MFA bootstrap did not complete")
                if self._option(connection, "mfaMethod") != "oauth":
                    raise Error("Trilium OIDC bootstrap did not complete")
        except sqlite3.Error as error:
            raise Error(f"failed to verify Trilium MFA: {error}") from error


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: object,
        code: int,
        message: str,
        headers: object,
        new_url: str,
    ) -> urllib.request.Request | None:
        return None


@dataclass(frozen=True)
class SetupClient:
    base_url: str
    timeout_seconds: float = 10

    def _request(self, path: str, data: bytes | None = None) -> tuple[int, bytes]:
        request = urllib.request.Request(f"{self.base_url}{path}", data=data)
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(request, timeout=self.timeout_seconds) as response:
                body = response.read(MAX_RESPONSE_BYTES + 1)
                status = response.status
        except urllib.error.HTTPError as error:
            body = error.read(MAX_RESPONSE_BYTES + 1)
            status = error.code
        if len(body) > MAX_RESPONSE_BYTES:
            raise Error(f"Trilium {path} response exceeds one MiB")
        return status, body

    def status(self) -> SetupStatus:
        status, body = self._request("/api/setup/status")
        if status != 200:
            raise Error(f"Trilium setup status returned HTTP {status}")
        try:
            return SetupStatus.model_validate_json(body)
        except ValidationError as error:
            raise Error("Trilium setup status returned an invalid response") from error

    def create_document(self) -> None:
        status, _ = self._request("/api/setup/new-document", data=b"")
        if status < 200 or status >= 400:
            raise Error(f"Trilium document initialization returned HTTP {status}")

    def set_password(self, password: bytes) -> None:
        data = urllib.parse.urlencode({"password1": password, "password2": password}).encode(
            "ascii"
        )
        status, _ = self._request("/set-password", data=data)
        if status != 302:
            raise Error(f"setting the Trilium break-glass password returned HTTP {status}")


class ServerProcess:
    def __init__(self, command: tuple[str, ...]) -> None:
        self.command = command
        self.process: subprocess.Popen[bytes] | None = None

    def __enter__(self) -> ServerProcess:
        self.process = subprocess.Popen(self.command)
        return self

    def __exit__(self, *exception: object) -> None:
        assert self.process is not None
        if self.process.poll() is not None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def exited(self) -> bool:
        assert self.process is not None
        return self.process.poll() is not None


def wait_until_ready(
    client: SetupClient,
    process: ServerProcess,
    timeout_seconds: float,
    poll_seconds: float,
) -> SetupStatus:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if process.exited():
            raise Error("Trilium exited before bootstrap completed")
        try:
            return client.status()
        except (OSError, Error):
            time.sleep(poll_seconds)
    raise Error("timed out waiting for Trilium's setup API")


def bootstrap(settings: Settings) -> None:
    database = TriliumDatabase(settings.database)
    initial = database.state()

    if not initial.initialized or not initial.password_set:
        client = SetupClient(settings.base_url)
        try:
            password = settings.password_file.read_bytes()
        except OSError as error:
            raise Error(f"failed to read Trilium password: {error}") from error
        if not password:
            raise Error("Trilium password is empty")

        with ServerProcess(settings.server_command) as process:
            status = wait_until_ready(
                client,
                process,
                settings.startup_timeout_seconds,
                settings.poll_seconds,
            )
            if not status.initialized:
                client.create_document()
            if not initial.password_set:
                client.set_password(password)

    final = database.state()
    if not final.initialized or not final.password_set:
        raise Error("Trilium database initialization did not complete")
    database.configure_mfa()
