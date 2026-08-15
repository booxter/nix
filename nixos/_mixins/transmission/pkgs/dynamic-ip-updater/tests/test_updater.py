from __future__ import annotations

import contextlib
import io
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from dynamic_ip_updater.cli import run


class UpdateHandler(BaseHTTPRequestHandler):
    success = True
    received_cookie = ""

    def do_GET(self) -> None:  # noqa: N802
        type(self).received_cookie = self.headers.get("Cookie", "")
        body = (
            b'{"Success":true,"message":"updated"}'
            if type(self).success
            else b'{"Success":false,"message":"rejected"}'
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "updated=yes; Path=/")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


@contextlib.contextmanager
def endpoint(*, success: bool) -> Iterator[str]:
    UpdateHandler.success = success
    UpdateHandler.received_cookie = ""
    server = ThreadingHTTPServer(("127.0.0.1", 0), UpdateHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}/dynamic"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def write_cookie_jar(path: Path) -> None:
    path.write_text(
        "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t2147483647\tsession\told\n"
    )
    path.chmod(0o600)


def invoke(cookie_path: Path, url: str) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = run(
        ["--cookie-jar", str(cookie_path), "--url", url, "--timeout-seconds", "2"],
        stdout,
        stderr,
    )
    return status, stdout.getvalue(), stderr.getvalue()


def test_success_uses_and_persists_the_native_cookie_jar(tmp_path: Path) -> None:
    cookie_path = tmp_path / "cookies.txt"
    write_cookie_jar(cookie_path)

    with endpoint(success=True) as url:
        status, stdout, stderr = invoke(cookie_path, url)

    assert status == 0
    assert stderr == ""
    assert '"Success":true' in stdout
    assert "session=old" in UpdateHandler.received_cookie
    assert "updated\tyes" in cookie_path.read_text()
    assert cookie_path.stat().st_mode & 0o777 == 0o600
    assert list(tmp_path.iterdir()) == [cookie_path]


def test_rejected_response_does_not_replace_cookie_jar(tmp_path: Path) -> None:
    cookie_path = tmp_path / "cookies.txt"
    write_cookie_jar(cookie_path)
    original = cookie_path.read_bytes()

    with endpoint(success=False) as url:
        status, stdout, stderr = invoke(cookie_path, url)

    assert status == 1
    assert stdout == ""
    assert '"Success":false' in stderr
    assert cookie_path.read_bytes() == original


@pytest.mark.parametrize("contents", [None, "", "not a cookie jar\n"])
def test_missing_empty_or_invalid_cookie_jar_fails_cleanly(
    tmp_path: Path,
    contents: str | None,
) -> None:
    cookie_path = tmp_path / "cookies.txt"
    if contents is not None:
        cookie_path.write_text(contents)

    status, stdout, stderr = invoke(cookie_path, "http://127.0.0.1:1/dynamic")

    assert status == 1
    assert stdout == ""
    assert stderr


def test_timeout_must_be_positive(tmp_path: Path) -> None:
    stdout = io.StringIO()
    stderr = io.StringIO()

    status = run(
        ["--cookie-jar", str(tmp_path / "cookies"), "--timeout-seconds", "0"],
        stdout,
        stderr,
    )

    assert status == 2
    assert "timeout must be positive" in stderr.getvalue()
