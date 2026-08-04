from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

TOKEN_LENGTH = 40
GROUPS = ("paperless-admins", "paperless-users")


class Error(RuntimeError):
    pass


@dataclass(frozen=True)
class UserSpec:
    username: str
    email: str
    password_environment: str
    is_staff: bool
    is_superuser: bool


USERS = (
    UserSpec(
        username="ihar",
        email="ihar.hrachyshka@gmail.com",
        password_environment="PAPERLESS_IHAR_PASSWORD_FILE",
        is_staff=True,
        is_superuser=True,
    ),
    UserSpec(
        username="kasia",
        email="",
        password_environment="PAPERLESS_KASIA_PASSWORD_FILE",
        is_staff=False,
        is_superuser=False,
    ),
)


class Repository(Protocol):
    def ensure_group(self, name: str) -> None: ...

    def reconcile_user(self, spec: UserSpec, password: str) -> None: ...

    def reconcile_primary_email(self, username: str, email: str) -> None: ...

    def reconcile_token(self, username: str, token: str) -> None: ...


def read_secret(path: Path) -> str:
    try:
        value = path.read_text().strip()
    except OSError as error:
        raise Error(f"failed to read Paperless secret from {path}") from error
    if not value:
        raise Error(f"Paperless secret is empty: {path}")
    return value


def required_path(environment: Mapping[str, str], name: str) -> Path:
    try:
        value = environment[name]
    except KeyError as error:
        raise Error(f"required Paperless environment variable is missing: {name}") from error
    path = Path(value)
    if not path.is_absolute():
        raise Error(f"Paperless secret path must be absolute: {name}")
    return path


def reconcile(repository: Repository, environment: Mapping[str, str]) -> None:
    passwords = {
        user.username: read_secret(required_path(environment, user.password_environment))
        for user in USERS
    }
    token = read_secret(required_path(environment, "PAPERLESS_GPT_API_TOKEN_FILE"))
    if len(token) != TOKEN_LENGTH:
        raise Error("PAPERLESS_GPT_API_TOKEN must be a 40-character Django REST token")

    for group in GROUPS:
        repository.ensure_group(group)
    for user in USERS:
        repository.reconcile_user(user, passwords[user.username])
        if user.email:
            repository.reconcile_primary_email(user.username, user.email)
    repository.reconcile_token("ihar", token)
