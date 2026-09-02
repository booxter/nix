from __future__ import annotations

import json
import urllib.parse
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from arr_post_processor.radarr import RadarrClient


def test_manual_import_scans_folder_without_download_id() -> None:
    requests: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            del format, args

        def do_GET(self) -> None:
            requests.append(self.path)
            body = json.dumps(
                [
                    {
                        "path": "/staging/attempt/Movie.mkv",
                        "quality": {"quality": {"id": 7, "name": "Bluray-1080p"}},
                        "rejections": [{"reason": "Unknown Movie"}],
                    }
                ]
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    @contextmanager
    def server() -> Iterator[str]:
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=httpd.serve_forever)
        thread.start()
        try:
            host, port = httpd.server_address
            yield f"http://{host}:{port}"
        finally:
            httpd.shutdown()
            thread.join()
            httpd.server_close()

    with server() as base_url:
        candidates = RadarrClient(base_url, "secret").manual_import(Path("/staging/attempt"))

    assert len(candidates) == 1
    assert candidates[0].path == Path("/staging/attempt/Movie.mkv")
    assert candidates[0].movie is None
    query = urllib.parse.parse_qs(
        urllib.parse.urlparse(requests[0]).query,
        keep_blank_values=True,
    )
    assert query["folder"] == ["/staging/attempt"]
    assert query["downloadId"] == [""]
