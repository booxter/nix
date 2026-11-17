import sys
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest
from claude_statusline.account import SecurityKeychain, UrllibUsageApi

USAGE = b'{"extra_usage": {"used_credits": 1539.0}}'


def fake_security(tmp_path: Path, script: str) -> str:
    executable = tmp_path / "security"
    executable.write_text(f"#!{sys.executable}\n{script}\n")
    executable.chmod(0o755)
    return str(executable)


def test_keychain_returns_the_saved_secret(tmp_path: Path) -> None:
    security = fake_security(tmp_path, "print('{\"claudeAiOauth\": {}}')")

    assert SecurityKeychain(security).read_credentials() == '{"claudeAiOauth": {}}\n'


def test_keychain_without_the_item_returns_nothing(tmp_path: Path) -> None:
    security = fake_security(tmp_path, "raise SystemExit(44)")

    assert SecurityKeychain(security).read_credentials() is None


def test_keychain_without_the_tool_returns_nothing(tmp_path: Path) -> None:
    assert SecurityKeychain(str(tmp_path / "missing")).read_credentials() is None


class UsageHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.headers["Authorization"] != "Bearer good":
            self.send_error(401)
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(USAGE)

    def log_message(self, format: str, *args: object) -> None:
        pass


@pytest.fixture
def usage_url() -> Iterator[str]:
    server = HTTPServer(("127.0.0.1", 0), UsageHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}/api/oauth/usage"
    server.shutdown()
    server.server_close()


def test_api_returns_usage_for_a_valid_token(usage_url: str) -> None:
    assert UrllibUsageApi(usage_url).get_usage("good") == USAGE.decode()


def test_api_rejecting_the_token_returns_nothing(usage_url: str) -> None:
    assert UrllibUsageApi(usage_url).get_usage("expired") is None


def test_unreachable_api_returns_nothing() -> None:
    # Port 9 (discard) is closed on loopback, so the connection is refused.
    assert UrllibUsageApi("http://127.0.0.1:9/").get_usage("good") is None
