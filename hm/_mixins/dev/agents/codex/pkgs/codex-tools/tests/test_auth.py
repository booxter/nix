import json
from pathlib import Path

import pytest

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError


def test_loads_tokens(tmp_path: Path) -> None:
    path = tmp_path / "auth.json"
    path.write_text(
        json.dumps({"tokens": {"access_token": "secret", "account_id": "account"}}),
        encoding="utf-8",
    )

    assert CodexAuth.load(path) == CodexAuth(access_token="secret", account_id="account")


@pytest.mark.parametrize(
    ("content", "message"),
    [
        ("{}", "No access token"),
        ('{"tokens":{"access_token":""}}', "No access token"),
        ("[]", "Expected a JSON object"),
        ("{", "Invalid JSON"),
    ],
)
def test_rejects_invalid_auth(tmp_path: Path, content: str, message: str) -> None:
    path = tmp_path / "auth.json"
    path.write_text(content, encoding="utf-8")

    with pytest.raises(CodexToolsError, match=message):
        CodexAuth.load(path)


def test_reports_missing_auth(tmp_path: Path) -> None:
    path = tmp_path / "missing.json"

    with pytest.raises(CodexToolsError, match="Codex auth file not found"):
        CodexAuth.load(path)


def test_reports_unreadable_auth_path(tmp_path: Path) -> None:
    with pytest.raises(CodexToolsError, match="Cannot read Codex auth file"):
        CodexAuth.load(tmp_path)
