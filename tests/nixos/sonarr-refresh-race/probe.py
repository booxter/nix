"""Verify overlapping refresh commands leave one Sonarr row per episode."""

import json
import re
import sys
import threading
import time
from collections import Counter, defaultdict
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

EPISODE_COUNT = 600


def serve_metadata(fixture_path):
    template = Path(fixture_path).read_text()
    request_counts = Counter()
    refresh_pairs = defaultdict(lambda: threading.Barrier(2, timeout=5))
    lock = threading.Lock()

    class MetadataHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/v1/dailyseries":
                self.send_json([])
                return

            show = re.fullmatch(r"/v2/tvdb/shows/eng/(\d+)/official", self.path)
            if show is None:
                self.send_error(404)
                return

            tvdb_id = int(show[1])
            series = json.loads(template)
            series.update(
                tvdbId=tvdb_id, title=f"Test Series {tvdb_id}", slug=f"test-series-{tvdb_id}"
            )
            episode = series["episodes"][0]
            series["episodes"] = [
                dict(
                    episode,
                    tvdbShowId=tvdb_id,
                    tvdbId=1000 * tvdb_id + number,
                    episodeNumber=number,
                )
                for number in range(1, EPISODE_COUNT + 1)
            ]
            series["seasonTypes"][0]["episodeCount"] = EPISODE_COUNT

            with lock:
                request_counts[tvdb_id] += 1
                request_number = request_counts[tvdb_id]
                pair = refresh_pairs[tvdb_id]

            # The add-series request reads metadata first. Release the next two
            # requests together to exercise concurrent episode reconciliation.
            if request_number in (2, 3):
                # A refresh that was already serialized can finish after the timeout.
                with suppress(threading.BrokenBarrierError):
                    pair.wait()

            self.send_json(series)

        def send_json(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    ThreadingHTTPServer(("127.0.0.1", 18080), MetadataHandler).serve_forever()


def request(path, payload=None):
    query = Request(
        f"http://127.0.0.1:8989/api/v3/{path}",
        data=None if payload is None else json.dumps(payload).encode(),
        headers={"X-Api-Key": "test-sonarr-api-key", "Content-Type": "application/json"},
    )
    with urlopen(query, timeout=30) as response:
        return json.load(response)


def add_series(tvdb_id, profile_id):
    return request(
        "series",
        {
            "title": f"Test Series {tvdb_id}",
            "tvdbId": tvdb_id,
            "qualityProfileId": profile_id,
            "rootFolderPath": "/srv/series",
            "monitored": False,
            "seasonFolder": True,
            "seriesType": "standard",
            "addOptions": {"searchForMissingEpisodes": False},
        },
    )["id"]


def wait_for_refreshes(series_id):
    deadline = time.monotonic() + 30
    refreshes = []
    while time.monotonic() < deadline:
        refreshes = [
            command
            for command in request("command")
            if command["name"] == "RefreshSeries" and command["body"]["seriesIds"] == [series_id]
        ]
        assert all(command["status"] != "failed" for command in refreshes), refreshes
        if len(refreshes) == 2 and all(command["status"] == "completed" for command in refreshes):
            return
        time.sleep(0.1)
    raise AssertionError(f"Expected two completed refreshes for series {series_id}: {refreshes}")


def check_refreshes():
    request("rootfolder", {"path": "/srv/series"})
    profile = request("qualityprofile")[0]["id"]
    expected = Counter((1, number) for number in range(1, EPISODE_COUNT + 1))

    # Repeat the overlapping public API calls on fresh series so a favorable
    # thread schedule on one attempt doesn't hide the race.
    for tvdb_id in range(1, 7):
        series_id = add_series(tvdb_id, profile)
        request("command", {"name": "RefreshSeries", "seriesId": series_id})
        wait_for_refreshes(series_id)

        rows = request(f"episode?seriesId={series_id}")
        episodes = Counter((row["seasonNumber"], row["episodeNumber"]) for row in rows)
        extra = sum((episodes - expected).values())
        missing = sum((expected - episodes).values())
        assert episodes == expected, (
            f"Series {series_id}: {extra} extra and {missing} missing episode rows"
        )

    print(f"Six refresh pairs each left {EPISODE_COUNT} distinct episodes")


if sys.argv[1] == "metadata":
    serve_metadata(sys.argv[2])
else:
    check_refreshes()
