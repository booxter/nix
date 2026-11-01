from __future__ import annotations

import fcntl
import json
import os
import stat
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from pydantic import SecretStr, ValidationError
from vikunja_provision.models import Credentials, ProvisionError


class CredentialStore(Protocol):
    def load(self) -> Credentials | None: ...

    def save(self, credentials: Credentials) -> None: ...


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


class FileCredentials:
    def __init__(self, path: Path) -> None:
        self.path = path

    @contextmanager
    def locked(self) -> Iterator[None]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            self.path.with_name(self.path.name + ".lock"), os.O_CREAT | os.O_RDWR, 0o600
        )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            os.close(descriptor)

    def load(self) -> Credentials | None:
        try:
            content = read_private_file(self.path)
        except FileNotFoundError:
            return None

        try:
            return Credentials.model_validate_json(content)
        except ValidationError as error:
            raise ProvisionError(f"Invalid credentials file: {self.path}") from error

    def save(self, credentials: Credentials) -> None:
        # SecretStr normally redacts JSON output; reveal it only for this private file.
        content = credentials.model_dump(mode="json")
        content["token"] = credentials.token.get_secret_value()
        write_text_atomic(self.path, json.dumps(content, indent=2) + "\n", mode=0o600)
