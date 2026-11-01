from __future__ import annotations

import fcntl
import hashlib
import json
import os
import stat
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pydantic import SecretStr, ValidationError
from sops_tools.cli import Application
from sops_tools.errors import ToolError
from sops_tools.model import KeyPath, has_path, value_at
from vikunja_provision.models import Credentials, ProvisionError, SopsState, SopsTarget


class CredentialStore(Protocol):
    def load(self) -> Credentials | None: ...

    def save(self, credentials: Credentials) -> None: ...


class SecretStore(Protocol):
    def read(self, host: str, target: SopsTarget) -> SecretStr | None: ...

    def write(self, host: str, target: SopsTarget, value: SecretStr) -> None: ...


@dataclass(frozen=True)
class SopsSecrets:
    application: Application

    def read(self, host: str, target: SopsTarget) -> SecretStr | None:
        try:
            service = self.application.secrets(target.realm)
            path = service.repository.require_secret(host)
            document = service.sops.decrypt_data(path)
            key = KeyPath.parse(target.key)
            if not has_path(document, key):
                return None

            value = value_at(document, key)
        except ToolError as error:
            raise ProvisionError(f"Could not read SOPS secret {host}:{target.key}") from error

        if not isinstance(value, str):
            raise ProvisionError(f"SOPS secret {host}:{target.key} must be a string")

        return SecretStr(value)

    def write(self, host: str, target: SopsTarget, value: SecretStr) -> None:
        try:
            self.application.secrets(target.realm).set_text(
                host, KeyPath.parse(target.key), value.get_secret_value()
            )
        except ToolError as error:
            raise ProvisionError(f"Could not update SOPS secret {host}:{target.key}") from error


@dataclass(frozen=True)
class SopsCredentials:
    target: SopsState
    secrets: SecretStore

    def load(self) -> Credentials | None:
        content = self.secrets.read(self.target.host, self.target)
        if content is None:
            return None

        try:
            return Credentials.model_validate_json(content.get_secret_value())
        except ValidationError as error:
            raise ProvisionError(
                f"Invalid credentials in SOPS secret {self.target.host}:{self.target.key}"
            ) from error

    def save(self, credentials: Credentials) -> None:
        # Keep token IDs and recovery state together in one encrypted JSON value.
        content = credentials.model_dump(mode="json")
        content["token"] = credentials.token.get_secret_value()
        self.secrets.write(self.target.host, self.target, SecretStr(json.dumps(content)))


@contextmanager
def provision_lock(server: str, bot: str) -> Iterator[None]:
    identity = hashlib.sha256(json.dumps([server, bot]).encode()).hexdigest()
    path = Path(tempfile.gettempdir()) / f"vikunja-provision-{os.getuid()}-{identity}.lock"
    # A stable, empty lock file serializes local runs without keeping any credentials.
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def read_private_file(path: Path) -> str:
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
        raise ProvisionError(f"{path} must be a regular file accessible only by its owner")

    return path.read_text(encoding="utf-8")


def read_session(path: Path) -> SecretStr:
    value = read_private_file(path).strip()
    if not value or any(character.isspace() for character in value) or value.startswith("tk_"):
        raise ProvisionError("Session file must contain a raw user-session token, not an API token")

    return SecretStr(value)
