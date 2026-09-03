from __future__ import annotations

import json
import urllib.parse
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from arr_post_processor.app import parse_source_roots
from arr_post_processor.lidarr import LidarrClient
from arr_post_processor.models import ManualImportFile, QueueRecord


def test_parse_named_source_roots() -> None:
    roots = parse_source_roots(["torrents=/downloads/lidarr", "usenet-manual=/usenet/manual"])

    assert [(root.name, root.host_path) for root in roots] == [
        ("torrents", Path("/downloads/lidarr")),
        ("usenet-manual", Path("/usenet/manual")),
    ]


def test_lidarr_client_catalog_and_import_round_trip() -> None:
    requests: list[tuple[str, str, object]] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            del format, args

        def send_json(self, payload: object) -> None:
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            requests.append(("GET", self.path, None))
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/v1/queue":
                self.send_json({"records": []})
            elif path == "/api/v1/album/8":
                self.send_json(
                    {
                        "id": 8,
                        "title": "Album",
                        "artistId": 7,
                        "artist": {"id": 7, "artistName": "Artist"},
                        "releases": [
                            {
                                "id": 9,
                                "title": "Album",
                                "mediumCount": 1,
                                "trackCount": 1,
                                "duration": 180000,
                            }
                        ],
                    }
                )
            elif path == "/api/v1/track":
                self.send_json(
                    [
                        {
                            "id": 10,
                            "title": "Track",
                            "mediumNumber": 1,
                            "trackNumber": 1,
                            "absoluteTrackNumber": 1,
                            "duration": 180000,
                        }
                    ]
                )
            elif path == "/api/v1/manualimport":
                self.send_json([])
            elif path == "/api/v1/command/12":
                self.send_json({"id": 12, "status": "completed"})
            else:
                self.send_error(404)

        def do_POST(self) -> None:
            length = int(self.headers["Content-Length"])
            payload = json.loads(self.rfile.read(length))
            requests.append(("POST", self.path, payload))
            self.send_json({"id": 12})

        def do_DELETE(self) -> None:
            requests.append(("DELETE", self.path, None))
            self.send_response(200)
            self.end_headers()

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

    record = QueueRecord(download_id="download-1", artist_id=7, album_id=8)
    with server() as base_url:
        client = LidarrClient(base_url, "secret")
        assert client.queue() == []
        catalog = client.album_catalog(8)
        assert catalog.album.artist.artist_name == "Artist"
        assert [track.id for track in catalog.releases[0].tracks] == [10]
        assert client.manual_import(Path("/staging/album"), record) == []
        assert (
            client.submit_manual_import(
                [
                    ManualImportFile(
                        path=Path("/staging/album/01.flac"),
                        artist_id=7,
                        album_id=8,
                        album_release_id=9,
                        track_ids=[10],
                        quality={},
                        download_id="download-1",
                        disable_release_switching=True,
                    )
                ]
            )
            == 12
        )
        assert client.command(12).status == "completed"

    track_query = urllib.parse.parse_qs(urllib.parse.urlparse(requests[2][1]).query)
    assert track_query == {"albumReleaseId": ["9"]}
    import_query = urllib.parse.parse_qs(urllib.parse.urlparse(requests[3][1]).query)
    assert import_query["replaceExistingFiles"] == ["False"]
    assert requests[4][0:2] == ("POST", "/api/v1/command")
    assert requests[4][2]["replaceExistingFiles"] is False  # type: ignore[index]
