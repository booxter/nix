"""Radarr lists two downloads. Only the completed movie is available in SABnzbd."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

VIDEO = Path(sys.argv[1])
FIXTURE = Path("/run/radarr-fixture")
COMPLETED_ID = "SABnzbd_nzo_complete"
UNFINISHED_ID = "SABnzbd_nzo_incomplete"
MOVIE = {"id": 42, "tmdbId": 123456, "title": "Example Movie", "year": 2026}
IMPORTS: list[dict[str, object]] = []
QUEUED = {"id": 1, "name": "ManualImport", "status": "queued"}


def page(*records: dict[str, object]) -> dict[str, object]:
    return {"page": 1, "pageSize": 250, "totalRecords": len(records), "records": records}


def radarr_queue() -> dict[str, object]:
    usenet = {"downloadClient": "SABnzbd", "protocol": "usenet", "statusMessages": []}
    blocked_import = {
        **usenet,
        "id": 101,
        "movieId": 42,
        "downloadId": COMPLETED_ID,
        "title": VIDEO.parent.name,
        "outputPath": str(VIDEO.parent),
        "status": "completed",
        "size": VIDEO.stat().st_size,
        "sizeleft": 0,
        "trackedDownloadStatus": "warning",
        "trackedDownloadState": "importBlocked",
    }
    if (FIXTURE / "missing-movie").exists():
        del blocked_import["movieId"]
    active_download = {
        **usenet,
        "id": 102,
        "movieId": 43,
        "downloadId": UNFINISHED_ID,
        "title": "Unfinished Movie",
        "outputPath": str(VIDEO.parent.parent / "Unfinished.Movie"),
        "status": "downloading",
        "size": 2000,
        "sizeleft": 1000,
        "trackedDownloadStatus": "ok",
        "trackedDownloadState": "downloading",
    }
    # Once Radarr accepts the import, the restarted daemon can find the
    # movie only through its saved attempt and Radarr's history.
    if IMPORTS:
        return page(active_download)
    return page(blocked_import, active_download)


def completed_download() -> dict[str, object]:
    return {
        "nzo_id": COMPLETED_ID,
        "name": VIDEO.parent.name,
        "status": "Completed",
        "storage": str(VIDEO),
        "loaded": False,
        "time_added": 1788549636,
        "completed": 1788552041,
        "bytes": VIDEO.stat().st_size,
        "category": "movies",
    }


def manual_import() -> dict[str, object]:
    return {
        "movie": {"id": 42},
        "downloadId": COMPLETED_ID,
        "path": str(VIDEO),
        "relativePath": VIDEO.name,
        "size": VIDEO.stat().st_size,
        "languages": [],
        "rejections": [],
        "quality": {"quality": {"id": 1, "name": "HDTV-720p"}},
    }


def import_record(history_id: int, file_id: int) -> dict[str, object]:
    return {
        "id": history_id,
        "eventType": "downloadFolderImported",
        "date": "2026-11-01T09:00:00Z",
        "movieId": MOVIE["id"],
        "sourceTitle": VIDEO.parent.name,
        "downloadId": COMPLETED_ID,
        "data": {
            "fileId": str(file_id),
            "droppedPath": str(VIDEO),
            "importedPath": "/movies/Example Movie (2026)/movie.mkv",
        },
    }


def import_history() -> dict[str, object]:
    # The older entry matches the movie, download and path, so only the
    # history baseline recorded before submission rules it out.
    records = [import_record(50, 7)]
    if IMPORTS:
        (FIXTURE / "history-checked").touch()
        if (FIXTURE / "publish-import").exists():
            records.append(import_record(51, 8))
    return page(*records)


def response_for(path: str, query: dict[str, list[str]]) -> object | None:
    if path == "/fixture/imports":
        return IMPORTS
    if path == "/api/v1/queue":
        return page()
    if path == "/api/v3/command/1":
        return QUEUED
    if path == "/api/v3/queue":
        return radarr_queue()
    if path == "/api/v3/movie/42":
        return MOVIE
    # When a queue entry loses its movie ID, Repairr searches by download ID alone.
    if (
        path == "/api/v3/history"
        and query.get("downloadId") == [COMPLETED_ID]
        and "movieIds" not in query
    ):
        return page() if (FIXTURE / "missing-movie").exists() else import_history()
    if (
        path == "/api/v3/history"
        and query.get("movieIds") == ["42"]
        and query.get("downloadId") == [COMPLETED_ID]
    ):
        return import_history()
    if path == "/api/v3/manualimport" and query.get("movieId") == ["42"]:
        return [manual_import()]

    if path == "/api" and query.get("nzo_ids") == [COMPLETED_ID]:
        return {"history": {"slots": [completed_download()]}}
    if path == "/api" and query.get("nzo_ids") == [UNFINISHED_ID]:
        return {"history": {"slots": []}}
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        request = urlsplit(self.path)
        payload = response_for(request.path, parse_qs(request.query))
        if payload is None:
            # Movie 43 has no collection endpoints. Fetching its facts would fail the scan.
            self.send_error(404)
            return

        self.send_json(payload)

    def do_POST(self) -> None:
        if self.path != "/api/v3/command":
            self.send_error(404)
            return
        IMPORTS.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        if (FIXTURE / "drop-reply").exists():
            # The command is already recorded. Close without sending HTTP headers.
            self.close_connection = True
            return
        self.send_json(QUEUED)

    def send_json(self, payload: object) -> None:
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", 7878), Handler).serve_forever()
