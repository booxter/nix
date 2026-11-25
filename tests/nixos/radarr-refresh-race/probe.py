"""Exercise Radarr's automatic and manual refreshes for the same movie."""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ALTERNATIVE_TITLES = [f"Alternate Title {number}" for number in range(1, 401)]
TERMINAL_STATUSES = {"completed", "failed", "aborted"}


def metadata_server(fixture_path, automatic_lookup, manual_lookup, release_refreshes):
    movie = json.loads(Path(fixture_path).read_text())
    refreshed_movie = {
        **movie,
        "alternativeTitles": [
            {"title": title, "type": "", "language": "en"} for title in ALTERNATIVE_TITLES
        ],
    }
    request_count = 0
    request_count_lock = threading.Lock()

    class MetadataHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal request_count

            if self.path != f"/v1/movie/{movie['tmdbId']}":
                self.send_error(404)
                return

            with request_count_lock:
                request_count += 1
                current_request = request_count

            # The add lookup returns no titles. Hold refresh lookups before either
            # can insert the new titles.
            if current_request == 2:
                automatic_lookup.set()
            elif current_request == 3:
                manual_lookup.set()

            if current_request > 1:
                release_refreshes.wait()

            self.send_json(movie if current_request == 1 else refreshed_movie)

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


class Api:
    def __init__(self):
        self.base = "http://127.0.0.1:7878/api/v3/"

    def request(self, path, payload=None):
        request = Request(
            self.base + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={
                "X-Api-Key": "radarr-refresh-test-key",
                "Content-Type": "application/json",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            body = error.read().decode()
            raise AssertionError(f"{path}: {error.code}: {body}") from error


def wait_for(predicate, description, timeout=30):
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {description}: {value}")


def terminal_refreshes(api, movie_id, manual_id):
    commands = [
        command
        for command in api.request("command")
        if command["name"] == "RefreshMovie"
        and command["body"]["movieIds"] == [movie_id]
        and (command["id"] == manual_id or command["body"]["isNewMovie"])
    ]
    if len(commands) == 2 and all(command["status"] in TERMINAL_STATUSES for command in commands):
        return commands
    return None


def check_refreshes(automatic_lookup, manual_lookup, release_refreshes):
    api = Api()
    api.request("rootfolder", {"path": "/srv/movies"})
    quality_profile_id = api.request("qualityprofile")[0]["id"]

    movie = api.request(
        "movie",
        {
            "title": "Reflink Movie",
            "tmdbId": 1,
            "qualityProfileId": quality_profile_id,
            "rootFolderPath": "/srv/movies",
            "monitored": False,
            "minimumAvailability": "released",
            "addOptions": {"searchForMovie": False},
        },
    )
    movie_id = movie["id"]
    wait_for(automatic_lookup.is_set, "the automatic refresh's metadata lookup")
    manual = api.request("command", {"name": "RefreshMovie", "movieIds": [movie_id]})

    # Both manual commands have the same priority. A worker can pick the later
    # health check only after it has picked or skipped the manual refresh.
    health_check = api.request("command", {"name": "CheckHealth"})
    wait_for(
        lambda: (
            manual_lookup.is_set()
            or api.request(f"command/{health_check['id']}")["status"] != "queued"
        ),
        "a worker to consider the manual refresh",
    )
    manual_status = api.request(f"command/{manual['id']}")["status"]
    if manual_status == "started":
        # Exercise the database race by releasing both responses together.
        wait_for(manual_lookup.is_set, "the overlapping manual refresh's metadata lookup")
        print("Both refreshes reached the metadata server before either could write", flush=True)
    release_refreshes.set()

    commands = wait_for(
        lambda: terminal_refreshes(api, movie_id, manual["id"]),
        f"automatic and manual refreshes for movie {movie_id}",
    )
    for command in commands:
        if command["status"] != "completed" or command["result"] != "successful":
            raise AssertionError(
                f"Refresh command {command['id']} for movie {movie_id} "
                f"ended with status {command['status']} and result {command['result']}: "
                f"{command.get('exception') or command['message']}"
            )

    # A lucky order of database writes can still leave both commands successful.
    if manual_status != "queued":
        raise AssertionError(
            f"Manual refresh was {manual_status} while the automatic refresh was blocked"
        )
    if not manual_lookup.is_set():
        raise AssertionError("The manual refresh completed without fetching metadata")

    refreshed_movie = api.request(f"movie/{movie_id}")
    alternative_titles = [title["title"] for title in refreshed_movie["alternateTitles"]]
    if sorted(alternative_titles) != sorted(ALTERNATIVE_TITLES):
        raise AssertionError(f"Unexpected alternative titles: {alternative_titles}")

    print(
        f"Both refreshes completed with {len(alternative_titles)} alternative titles",
        flush=True,
    )


def main(fixture_path):
    automatic_lookup = threading.Event()
    manual_lookup = threading.Event()
    release_refreshes = threading.Event()
    with metadata_server(
        fixture_path, automatic_lookup, manual_lookup, release_refreshes
    ) as server:
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            check_refreshes(automatic_lookup, manual_lookup, release_refreshes)
        finally:
            release_refreshes.set()
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main(sys.argv[1])
