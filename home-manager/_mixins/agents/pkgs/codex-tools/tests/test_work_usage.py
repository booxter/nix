import io
import json
from pathlib import Path

import pytest

from codex_tools.auth import CodexAuth
from codex_tools.cli import work_usage_main
from codex_tools.errors import CodexToolsError
from codex_tools.usage import USAGE_ENDPOINT
from codex_tools.work_usage import WorkUsageService, format_work_usage, normalize_work_usage
from fakes import FakeJsonHttpClient


def work_response() -> dict[str, object]:
    return {
        "account_id": "response-account",
        "email": "user@example.com",
        "plan_type": "team",
        "spend_control": {
            "reached": False,
            "individual_limit": {
                "source": "monthly",
                "limit": "1000",
                "used": 250,
                "remaining": "750.5",
                "used_percent": "25",
                "remaining_percent": 75,
                "reset_after_seconds": "1392000",
                "reset_at": 1_701_388_800,
            },
        },
        "credits": {
            "has_credits": True,
            "unlimited": False,
            "overage_limit_reached": False,
            "balance": "12.5",
        },
    }


def test_fetches_and_normalizes_work_usage() -> None:
    client = FakeJsonHttpClient({USAGE_ENDPOINT: work_response()})

    usage = WorkUsageService(client).fetch(
        CodexAuth("test-token", "test-account"),
        now=1_700_000_000,
    )

    assert usage.limit == 1000
    assert usage.remaining == 750.5
    assert usage.window_start_at == 1_698_796_800
    assert usage.window_seconds == 2_592_000
    assert usage.elapsed_seconds == 1_203_200
    assert usage.credits.balance == 12.5
    assert client.requests[0].headers == {
        "Authorization": "Bearer test-token",
        "ChatGPT-Account-Id": "test-account",
        "OAI-Language": "en-US",
        "originator": "codex_desktop",
    }


def test_rejects_missing_limit_and_account() -> None:
    with pytest.raises(CodexToolsError, match="Missing spend_control.individual_limit"):
        normalize_work_usage({}, now=0)

    with pytest.raises(CodexToolsError, match="account ID is required"):
        WorkUsageService(FakeJsonHttpClient({})).fetch(CodexAuth("token", None), now=0)


def test_formats_missing_values() -> None:
    usage = normalize_work_usage(
        {"spend_control": {"individual_limit": {"limit": "invalid"}}},
        now=0,
    )

    assert format_work_usage(usage).splitlines() == [
        "remaining: ?%",
        "used: ?%",
        "credits: ? / ?",
        "reset_after_seconds: ?",
        "reset_at: ?",
    ]


def test_work_usage_main_writes_json(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    auth_path.write_text(
        json.dumps({"tokens": {"access_token": "token", "account_id": "account"}}),
        encoding="utf-8",
    )
    stdout = io.StringIO()

    status = work_usage_main(
        ["--json", "--auth-file", str(auth_path)],
        client=FakeJsonHttpClient({USAGE_ENDPOINT: work_response()}),
        now=1_700_000_000,
        stdout=stdout,
    )

    assert status == 0
    assert json.loads(stdout.getvalue())["remaining_percent"] == 75


def test_work_usage_main_requires_account_id(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    auth_path.write_text(json.dumps({"tokens": {"access_token": "token"}}), encoding="utf-8")
    stderr = io.StringIO()

    status = work_usage_main(
        ["--auth-file", str(auth_path)],
        client=FakeJsonHttpClient({}),
        stderr=stderr,
    )

    assert status == 1
    assert f"No account id found in {auth_path}" in stderr.getvalue()
