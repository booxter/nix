from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import SecretStr, ValidationError
from vikunja_provision.models import Credentials, Declaration, ProvisionError
from vikunja_provision.storage import FileCredentials, read_session


def test_private_credentials_survive_reload(tmp_path: Path) -> None:
    path = tmp_path / "state" / "credentials.json"
    store = FileCredentials(path)
    credentials = Credentials(
        server="https://example.test", bot_id=1, token_id=2, token=SecretStr("tk_private")
    )

    with store.locked():
        assert store.load() is None
        store.save(credentials)

    assert FileCredentials(path).load() == credentials
    assert path.stat().st_mode & 0o777 == 0o600
    assert "tk_private" not in repr(credentials)


def test_malformed_credentials_are_reported_without_secret_values(tmp_path: Path) -> None:
    path = tmp_path / "credentials.json"
    path.write_text('{"token": "tk_private"}', encoding="utf-8")
    path.chmod(0o600)

    with pytest.raises(ProvisionError, match="Invalid credentials") as error:
        FileCredentials(path).load()

    assert "tk_private" not in str(error.value)


def test_credentials_with_broad_permissions_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "credentials.json"
    path.write_text("private", encoding="utf-8")
    path.chmod(0o644)

    with pytest.raises(ProvisionError, match="accessible only by its owner"):
        FileCredentials(path).load()


@pytest.mark.parametrize("value", ["", "tk_api_token", "Bearer session", "session\nother"])
def test_session_file_requires_a_raw_user_session(tmp_path: Path, value: str) -> None:
    path = tmp_path / "session"
    path.write_text(value, encoding="utf-8")
    path.chmod(0o600)

    with pytest.raises(ProvisionError, match="raw user-session"):
        read_session(path)


@pytest.mark.parametrize(
    "server",
    [
        "http://example.test",
        "https://user:secret@example.test",
        "https://example.test/?token=secret",
        "https://example.test/#secret",
    ],
)
def test_declaration_rejects_unsafe_server_urls(declaration: Declaration, server: str) -> None:
    body = declaration.model_dump(mode="json")
    body["server"] = server
    with pytest.raises(ValidationError):
        Declaration.model_validate(body)


def test_declaration_rejects_duplicate_projects_and_missing_mcp_scope(
    declaration: Declaration,
) -> None:
    declaration.projects.append(declaration.projects[0])
    with pytest.raises(ValidationError, match="unique"):
        Declaration.model_validate_json(declaration.model_dump_json())

    declaration.projects.clear()
    declaration.token.permissions.clear()
    with pytest.raises(ValidationError, match=r"mcp\.access"):
        Declaration.model_validate_json(declaration.model_dump_json())
