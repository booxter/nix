"""Overlap an automatic artist refresh with a manual album refresh."""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

RELEASE_COUNT = 300
TERMINAL_STATUSES = {"completed", "failed", "aborted"}


def identifier(prefix, number):
    return f"{prefix * 8}-{prefix * 4}-4{prefix * 3}-8{prefix * 3}-{number:012d}"


def metadata_server(automatic_lookup, manual_lookup, release_refreshes):
    artist = json.loads(Path("/etc/lidarr-artist.json").read_text())
    album = json.loads(Path("/etc/lidarr-album.json").read_text())
    release = album["releases"][0]
    track = release["tracks"][0]
    album["releases"] = [
        {
            **release,
            "id": identifier("3", number),
            "title": f"Release {number}",
            "tracks": [
                {
                    **track,
                    "id": identifier("4", number),
                    "recordingId": identifier("5", number),
                    "trackName": f"Track {number}",
                }
            ],
        }
        for number in range(1, RELEASE_COUNT + 1)
    ]
    album_requests = 0
    lock = threading.Lock()

    class MetadataHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal album_requests

            if self.path == f"/api/v0.4/artist/{artist['id']}":
                self.send_json(artist)
            elif self.path == f"/api/v0.4/album/{album['id']}":
                with lock:
                    album_requests += 1
                    current_request = album_requests

                if current_request == 1:
                    automatic_lookup.set()
                elif current_request == 2:
                    manual_lookup.set()

                release_refreshes.wait()
                self.send_json(album)
            else:
                self.send_error(404)

        def send_json(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *_args):
            pass

    return ThreadingHTTPServer(("127.0.0.1", 18080), MetadataHandler)


def request(path, payload=None):
    query = Request(
        f"http://127.0.0.1:8686/api/v1/{path}",
        data=None if payload is None else json.dumps(payload).encode(),
        headers={"X-Api-Key": "lidarr-refresh-test-key", "Content-Type": "application/json"},
    )
    with urlopen(query, timeout=30) as response:
        return json.load(response)


def wait_for(predicate, description):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {description}")


def check_refreshes(automatic_lookup, manual_lookup, release_refreshes):
    quality_profile = request("qualityprofile")[0]["id"]
    metadata_profile = request("metadataprofile")[0]["id"]
    request(
        "rootfolder",
        {
            "name": "Music",
            "path": "/srv/music",
            "defaultQualityProfileId": quality_profile,
            "defaultMetadataProfileId": metadata_profile,
            "defaultMonitorOption": "none",
            "defaultNewItemMonitorOption": "none",
        },
    )
    artist = request(
        "artist",
        {
            "artistName": "Reflink Artist",
            "foreignArtistId": "11111111-1111-4111-8111-111111111111",
            "qualityProfileId": quality_profile,
            "metadataProfileId": metadata_profile,
            "rootFolderPath": "/srv/music",
            "monitored": False,
            "addOptions": {"searchForMissingAlbums": False},
        },
    )
    wait_for(automatic_lookup.is_set, "the automatic artist refresh's album lookup")
    album = request(f"album?artistId={artist['id']}")[0]
    manual = request("command", {"name": "RefreshAlbum", "albumId": album["id"]})
    wait_for(manual_lookup.is_set, "the manual album refresh's overlapping lookup")
    print("Artist and album refreshes both reached the album metadata lookup", flush=True)
    release_refreshes.set()

    def terminal_refreshes():
        commands = [
            command
            for command in request("command")
            if command["id"] == manual["id"]
            or (
                command["name"] == "RefreshArtist"
                and command["body"]["artistIds"] == [artist["id"]]
            )
        ]
        if len(commands) == 2 and all(c["status"] in TERMINAL_STATUSES for c in commands):
            return commands
        return None

    commands = wait_for(terminal_refreshes, "both refresh commands to finish")
    for command in commands:
        assert command["status"] == "completed" and command["result"] == "successful", command

    releases = request(f"album/{album['id']}")["releases"]
    expected = {identifier("3", number) for number in range(1, RELEASE_COUNT + 1)}
    actual = [release["foreignReleaseId"] for release in releases]
    assert len(actual) == len(expected) and set(actual) == expected, actual
    tracks = [
        track for release in releases for track in request(f"track?albumReleaseId={release['id']}")
    ]
    expected_tracks = {identifier("4", number) for number in range(1, RELEASE_COUNT + 1)}
    actual_tracks = [track["foreignTrackId"] for track in tracks]
    assert len(actual_tracks) == len(expected_tracks) and set(actual_tracks) == expected_tracks, (
        tracks
    )
    print(f"Both refreshes completed with {len(releases)} releases and {len(tracks)} tracks")


def main():
    automatic_lookup = threading.Event()
    manual_lookup = threading.Event()
    release_refreshes = threading.Event()
    with metadata_server(automatic_lookup, manual_lookup, release_refreshes) as server:
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            check_refreshes(automatic_lookup, manual_lookup, release_refreshes)
        finally:
            release_refreshes.set()
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
