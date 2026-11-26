"""One album is waiting for import. Its two tracks appear in history separately."""

import json
import os
import sys
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

DOWNLOAD = Path(sys.argv[1])
ARTIST = {"id": 7, "artistName": "Example Artist"}
RELEASE = {
    "id": 81,
    "albumId": 3,
    "title": "Example Album",
    "foreignReleaseId": "example-release",
    "trackCount": 2,
    "mediumCount": 1,
    "format": "CD",
    "monitored": True,
}
ALBUM = {
    "id": 3,
    "title": "Example Album",
    "artistId": ARTIST["id"],
    "artist": ARTIST,
    "releases": [RELEASE],
    "monitored": True,
}
QUEUE_ENTRY = {
    "id": 42,
    "artistId": ARTIST["id"],
    "albumId": ALBUM["id"],
    "title": ALBUM["title"],
    "downloadId": "SABnzbd_nzo_album",
    "downloadClient": "SABnzbd",
    "protocol": "usenet",
    "status": "completed",
    "trackedDownloadStatus": "warning",
    "outputPath": str(DOWNLOAD),
}
TRACKS = [
    {
        "id": track_id,
        "albumId": ALBUM["id"],
        "artistId": ARTIST["id"],
        "title": title,
        "trackNumber": str(number),
        "absoluteTrackNumber": number,
        "mediumNumber": 1,
        "duration": 1000,
    }
    for number, track_id, title in [(1, 12, "First track"), (2, 11, "Second track")]
]
TRACKS_BY_RELEASE = {81: TRACKS}
if os.environ.get("OFFER_REISSUE"):
    ALBUM["releases"].append(
        {
            **RELEASE,
            "id": 82,
            "title": "Example Album Reissue",
            "foreignReleaseId": "example-reissue",
            "monitored": False,
        }
    )
    # Both editions contain the same songs in the same order, with distinct
    # Lidarr track IDs. The operator's edition choice determines those IDs.
    TRACKS_BY_RELEASE[82] = [{**track, "id": track["id"] + 10} for track in TRACKS]
COMMAND = {"id": 1, "name": "ManualImport", "status": "completed"}
PUBLISH_SECOND = Path("/run/lidarr-fixture/publish-second-track")


def page(records):
    return {"page": 1, "pageSize": 250, "totalRecords": len(records), "records": records}


class AlbumImport:
    def __init__(self):
        self.commands = []
        self.workspace = None
        self.imported_at = None

    def queue(self):
        if self.commands:
            return page([])
        if Path("/run/lidarr-fixture/downloading").exists():
            return page([{**QUEUE_ENTRY, "status": "downloading"}])
        return page([QUEUE_ENTRY])

    def manual_imports(self, folder):
        self.workspace = Path(folder)
        files = []
        for track in TRACKS:
            path = self.workspace / f"{track['absoluteTrackNumber']:02}.flac"
            files.append(
                {
                    "path": str(path),
                    "name": path.name,
                    "size": path.stat().st_size,
                    "artist": ARTIST,
                    "album": {"id": ALBUM["id"]},
                    "albumReleaseId": RELEASE["id"],
                    "tracks": [track],
                    "quality": {"quality": {"id": 1, "name": "FLAC"}},
                }
            )
        return files

    def submit(self, command):
        self.commands.append(command)
        self.imported_at = datetime.now(UTC).isoformat()

    def history(self):
        if not self.commands:
            return page([])
        release_id = self.commands[-1]["files"][0]["albumReleaseId"]
        tracks = TRACKS_BY_RELEASE[release_id]
        visible = tracks if PUBLISH_SECOND.exists() else tracks[:1]
        records = []
        for track in visible:
            number = track["absoluteTrackNumber"]
            name = f"{number:02}.flac"
            records.append(
                {
                    "id": 90 + number,
                    "eventType": "trackFileImported",
                    "date": self.imported_at,
                    "albumId": ALBUM["id"],
                    "artistId": ARTIST["id"],
                    "trackId": track["id"],
                    "data": {
                        "droppedPath": str(self.workspace / name),
                        "importedPath": f"/music/Example Album/{name}",
                    },
                }
            )
        return page(records)


album = AlbumImport()


class Lidarr(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        match url.path:
            case "/api/v3/queue":
                payload = page([])  # Radarr has no jobs in this VM.
            case "/api/v1/queue":
                payload = album.queue()
            case "/api/v1/album/3":
                payload = ALBUM
            case "/api/v1/track" if "albumReleaseId" in query:
                payload = TRACKS_BY_RELEASE[int(query["albumReleaseId"][0])]
                if Path("/run/lidarr-fixture/library-complete").exists():
                    payload = [
                        {**track, "hasFile": True, "trackFileId": track["id"]} for track in payload
                    ]
            case "/api/v1/manualimport" if query.get("artistId") == ["7"]:
                payload = album.manual_imports(query["folder"][0])
            case "/api/v1/history" if query.get("albumId") == ["3"]:
                payload = album.history()
            case "/api/v1/command/1":
                payload = COMMAND
            case "/fixture/imports":
                payload = album.commands
            case _:
                self.send_error(404)
                return
        self.send_json(payload)

    def do_POST(self):
        if self.path != "/api/v1/command":
            self.send_error(404)
            return
        album.submit(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_json(COMMAND)

    def send_json(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", 7878), Lidarr).serve_forever()
