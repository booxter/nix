import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from curl_cffi import requests
from letterboxd_sync.cli import main
from letterboxd_sync.jellyfin import connect
from letterboxd_sync.models import SyncError
from letterboxd_sync.state import Cookies
from letterboxd_sync.transport import HttpTransport, Upload


def seed(path: Path, value: str) -> None:
    path.write_text(
        f"# Netscape HTTP Cookie File\n.letterboxd.com\tTRUE\t/\tTRUE\t0\tsession\t{value}\n"
    )


def test_cookies_persist_rotation_but_new_seed_wins(tmp_path):
    source = tmp_path / "seed"
    seed(source, "old")
    cookies = Cookies(source, tmp_path)
    next(iter(cookies.jar)).value = "rotated"
    cookies.save()
    assert next(iter(Cookies(source, tmp_path).jar)).value == "rotated"
    seed(source, "replacement")
    assert next(iter(Cookies(source, tmp_path).jar)).value == "replacement"
    assert (tmp_path / "cookies.txt").stat().st_mode & 0o777 == 0o600


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/Users":
            content = [{"Id": "abc123", "Name": "source"}]
        elif self.path.startswith("/Items?"):
            content = {"Items": [], "TotalRecordCount": 0}
        else:
            content = "ok"

        statuses = {"/blocked": 403, "/redirect": 302}
        route = "/" + self.path.split("/")[1]
        status = statuses.get(route, 200)
        self.send_response(status)
        self.end_headers()
        body = content if isinstance(content, str) else json.dumps(content)
        self.wfile.write(body.encode())

    def do_POST(self):
        content = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *args):
        pass


@pytest.fixture
def transport():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()

    try:
        with requests.Session() as session:
            yield HttpTransport(f"http://127.0.0.1:{server.server_port}", session)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


def test_http_transport_get_forms_and_multipart(transport):
    assert transport.request("GET", "/") == "ok"
    assert transport.request("POST", "/", data=b"x=a%26b") == "x=a%26b"
    body = transport.request(
        "POST", "/", data={"__csrf": "test"}, upload=Upload("watched.csv", b"imdbID\ntt1\n")
    )
    assert 'filename="watched.csv"' in body
    assert "imdbID\ntt1\n" in body
    assert "test" in body


def test_jellyfin_bindings_read_users_and_library(transport):
    with connect(transport.base_url, "test-key") as source:
        assert source.watched("source") == set()


def test_jellyfin_bindings_report_server_errors(transport):
    with (
        pytest.raises(SyncError, match="Unable to query Jellyfin"),
        connect(transport.base_url + "/blocked", "test-key") as source,
    ):
        source.watched("source")


@pytest.mark.parametrize(
    "path", ["/blocked", "/redirect", "//other.example", "https://other.example"]
)
def test_http_errors_and_redirects_fail_closed(transport, path):
    with pytest.raises(SyncError):
        transport.request("GET", path)


def test_transport_error_has_no_credentials():
    with requests.Session() as session, pytest.raises(SyncError, match="connectivity"):
        HttpTransport("http://127.0.0.1:0", session).request("GET", "/")


def arguments(tmp_path):
    return [
        "--config",
        str(tmp_path / "config"),
        "--credentials",
        str(tmp_path),
        "--state",
        str(tmp_path / "state"),
    ]


def test_cli_redacts_invalid_secrets(tmp_path, capsys):
    (tmp_path / "config").write_text('{"jellyfin_url": "https://example.com"}')
    (tmp_path / "account").write_text('{"secret": "do-not-print-me"}')
    assert main(arguments(tmp_path)) == 1
    assert "do-not-print-me" not in capsys.readouterr().out


def test_cli_reports_missing_credentials(tmp_path):
    assert main(arguments(tmp_path)) == 1


def test_cli_rejects_plaintext_jellyfin(tmp_path):
    (tmp_path / "config").write_text('{"jellyfin_url": "http://example.com"}')
    (tmp_path / "account").write_text(
        json.dumps(
            {
                "jellyfin_user": "source",
                "letterboxd_user": "example",
            }
        )
    )
    assert main(arguments(tmp_path)) == 1


def test_cli_rejects_empty_api_key(tmp_path):
    (tmp_path / "config").write_text('{"jellyfin_url": "https://example.com"}')
    (tmp_path / "account").write_text(
        json.dumps(
            {
                "jellyfin_user": "source",
                "letterboxd_user": "example",
            }
        )
    )
    seed(tmp_path / "cookies", "test")
    (tmp_path / "jellyfin-key").write_text("")
    assert main(arguments(tmp_path)) == 1
