import io
import json
from pathlib import Path

from codex_tools.cli import usage_main
from codex_tools.usage import RESET_CREDITS_ENDPOINT, USAGE_ENDPOINT
from fakes import FakeJsonHttpClient


def write_auth(path: Path) -> None:
    path.write_text(json.dumps({"tokens": {"access_token": "test-token"}}), encoding="utf-8")


def test_usage_main_writes_normalized_json(tmp_path: Path) -> None:
    auth_path = tmp_path / "auth.json"
    write_auth(auth_path)
    stdout = io.StringIO()
    client = FakeJsonHttpClient(
        {
            USAGE_ENDPOINT: {
                "rate_limit": {
                    "allowed": True,
                    "limit_reached": False,
                    "primary_window": {
                        "used_percent": 12.4,
                        "limit_window_seconds": 18_000,
                    },
                }
            },
            RESET_CREDITS_ENDPOINT: {"available_count": 0, "credits": []},
        }
    )

    status = usage_main(
        ["--json", "--auth-file", str(auth_path)],
        client=client,
        now=0,
        stdout=stdout,
    )

    assert status == 0
    assert json.loads(stdout.getvalue())["windows"]["five_hour"]["remaining_percent"] == 87


def test_usage_main_reports_auth_error(tmp_path: Path) -> None:
    stderr = io.StringIO()

    status = usage_main(
        ["--auth-file", str(tmp_path / "missing.json")],
        client=FakeJsonHttpClient({}),
        stderr=stderr,
    )

    assert status == 1
    assert "Codex auth file not found" in stderr.getvalue()
