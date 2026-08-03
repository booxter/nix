import io
import json
from pathlib import Path

import pytest

from codex_tools.auth import CodexAuth
from codex_tools.cli import reset_credits_main
from codex_tools.errors import CodexToolsError
from codex_tools.reset_credits import (
    ResetCreditsReport,
    ResetCreditsService,
    format_reset_credits,
)
from codex_tools.usage import RESET_CREDITS_ENDPOINT
from fakes import FakeJsonHttpClient


def test_fetches_and_formats_reset_credits() -> None:
    client = FakeJsonHttpClient(
        {
            RESET_CREDITS_ENDPOINT: {
                "available_count": 2,
                "credits": [
                    {"expires_at": "2026-08-03T12:00:00Z"},
                    {},
                ],
            }
        }
    )

    report = ResetCreditsService(client).fetch(CodexAuth("test-token", None))

    assert report == ResetCreditsReport(
        available_count=2,
        expirations=("2026-08-03T12:00:00Z", None),
    )
    assert format_reset_credits(report).splitlines() == [
        "available_count: 2",
        "credits:",
        "  - expires_at: 2026-08-03T12:00:00Z",
        "  - expires_at: <missing>",
    ]
    assert client.requests[0].headers == {"Authorization": "Bearer test-token"}


def test_rejects_missing_available_count() -> None:
    with pytest.raises(CodexToolsError, match="missing available_count"):
        ResetCreditsReport.from_json({"credits": []})


def test_rejects_malformed_credits() -> None:
    with pytest.raises(CodexToolsError, match="Invalid reset credits response"):
        ResetCreditsReport.from_json({"available_count": 1, "credits": ["invalid"]})


def test_reset_credits_main_accepts_positional_auth_file(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    auth_path.write_text(json.dumps({"tokens": {"access_token": "token"}}), encoding="utf-8")
    stdout = io.StringIO()

    status = reset_credits_main(
        [str(auth_path)],
        client=FakeJsonHttpClient({RESET_CREDITS_ENDPOINT: {"available_count": 0, "credits": []}}),
        stdout=stdout,
    )

    assert status == 0
    assert stdout.getvalue() == "available_count: 0\ncredits:\n"


def test_reset_credits_main_reports_invalid_response(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    auth_path.write_text(json.dumps({"tokens": {"access_token": "token"}}), encoding="utf-8")
    stderr = io.StringIO()

    status = reset_credits_main(
        [str(auth_path)],
        client=FakeJsonHttpClient({RESET_CREDITS_ENDPOINT: {}}),
        stderr=stderr,
    )

    assert status == 1
    assert "missing available_count" in stderr.getvalue()
