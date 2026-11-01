from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import SecretStr, ValidationError
from vikunja_provision.models import Credentials, Declaration, ProvisionError
from vikunja_provision.storage import SopsCredentials, read_session

from .fakes import MemoryTokenStore


def test_credentials_survive_reload(declaration: Declaration) -> None:
    secrets = MemoryTokenStore()
    store = SopsCredentials(declaration.state, secrets)
    credentials = Credentials(
        server="https://example.test",
        bot_id=1,
        token_id=2,
        token=SecretStr("tk_private"),
        previous_token_id=1,
    )

    assert store.load() is None
    store.save(credentials)

    assert SopsCredentials(declaration.state, secrets).load() == credentials
    assert "tk_private" not in repr(credentials)


def test_malformed_credentials_are_reported_without_secret_values(declaration: Declaration) -> None:
    secrets = MemoryTokenStore(values={"org": SecretStr('{"token": "tk_private"}')})

    with pytest.raises(ProvisionError, match="Invalid credentials") as error:
        SopsCredentials(declaration.state, secrets).load()

    assert "tk_private" not in str(error.value)


def test_session_with_broad_permissions_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "session"
    path.write_text("private", encoding="utf-8")
    path.chmod(0o644)

    with pytest.raises(ProvisionError, match="accessible only by its owner"):
        read_session(path)


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
