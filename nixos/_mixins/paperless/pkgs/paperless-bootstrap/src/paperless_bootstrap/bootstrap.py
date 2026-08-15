from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast

TOKEN_LENGTH = 40


class Error(RuntimeError):
    pass


@dataclass(frozen=True)
class UserSpec:
    username: str
    email: str
    password_file: Path
    is_staff: bool
    is_superuser: bool


@dataclass(frozen=True)
class TokenSpec:
    owner: str
    file: Path


@dataclass(frozen=True)
class BootstrapSpec:
    groups: tuple[str, ...]
    users: tuple[UserSpec, ...]
    token: TokenSpec


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


def required_mapping(value: object, context: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise Error(f"Paperless bootstrap {context} must be an object")
    return cast(Mapping[str, object], value)


def required_string(mapping: Mapping[str, object], name: str, context: str) -> str:
    value = mapping.get(name)
    if not isinstance(value, str) or not value:
        raise Error(f"Paperless bootstrap {context}.{name} must be a non-empty string")
    return value


def required_bool(mapping: Mapping[str, object], name: str, context: str) -> bool:
    value = mapping.get(name)
    if not isinstance(value, bool):
        raise Error(f"Paperless bootstrap {context}.{name} must be a boolean")
    return value


def string_or_empty(mapping: Mapping[str, object], name: str) -> str:
    value = mapping.get(name)
    return value if isinstance(value, str) else ""


def required_path(mapping: Mapping[str, object], name: str, context: str) -> Path:
    path = Path(required_string(mapping, name, context))
    if not path.is_absolute():
        raise Error(f"Paperless bootstrap {context}.{name} must be an absolute path")
    return path


def load_spec(path: Path) -> BootstrapSpec:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise Error(f"failed to read Paperless bootstrap configuration from {path}") from error
    root = required_mapping(document, "configuration")

    raw_groups = root.get("groups")
    if not isinstance(raw_groups, list) or not all(
        isinstance(group, str) and group for group in raw_groups
    ):
        raise Error("Paperless bootstrap groups must be a list of non-empty strings")
    groups = tuple(cast(list[str], raw_groups))

    raw_users = root.get("users")
    if not isinstance(raw_users, list) or not raw_users:
        raise Error("Paperless bootstrap users must be a non-empty list")
    users = tuple(
        UserSpec(
            username=required_string(user, "username", f"users[{index}]"),
            email=string_or_empty(user, "email"),
            password_file=required_path(user, "passwordFile", f"users[{index}]"),
            is_staff=required_bool(user, "isStaff", f"users[{index}]"),
            is_superuser=required_bool(user, "isSuperuser", f"users[{index}]"),
        )
        for index, item in enumerate(raw_users)
        for user in [required_mapping(item, f"users[{index}]")]
    )

    token = required_mapping(root.get("token"), "token")
    token_spec = TokenSpec(
        owner=required_string(token, "owner", "token"),
        file=required_path(token, "file", "token"),
    )
    if token_spec.owner not in {user.username for user in users}:
        raise Error("Paperless bootstrap token owner must name a declared user")
    return BootstrapSpec(groups=groups, users=users, token=token_spec)


def reconcile(repository: Repository, spec: BootstrapSpec) -> None:
    passwords = {user.username: read_secret(user.password_file) for user in spec.users}
    token = read_secret(spec.token.file)
    if len(token) != TOKEN_LENGTH:
        raise Error("Paperless API token must be a 40-character Django REST token")

    for group in spec.groups:
        repository.ensure_group(group)
    for user in spec.users:
        repository.reconcile_user(user, passwords[user.username])
        if user.email:
            repository.reconcile_primary_email(user.username, user.email)
    repository.reconcile_token(spec.token.owner, token)
