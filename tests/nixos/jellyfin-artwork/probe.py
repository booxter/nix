"""Exercise the real Jellyfin/TMDb image pipeline without external network access."""

import hashlib
import json
import os
import shutil
import sys
import time
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def serve(fixtures):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path.startswith("/images/"):
                image = fixtures / Path(path).name
                self.send_body(image.read_bytes(), "image/png")
                return

            if path == "/3/configuration":
                result = {
                    "images": {
                        "base_url": "http://127.0.0.1:18080/images/",
                        "secure_base_url": "http://127.0.0.1:18080/images/",
                        "poster_sizes": ["original"],
                        "backdrop_sizes": ["original"],
                        "logo_sizes": ["original"],
                        "profile_sizes": ["original"],
                        "still_sizes": ["original"],
                    }
                }
            elif path == "/3/movie/9595":
                result = {
                    "id": 9595,
                    "title": "Artwork Fixture",
                    "original_title": "Artwork Fixture",
                    "release_date": "1991-07-31",
                    "adult": False,
                    "images": {
                        "posters": [image_info("poster.png", 64, 96)],
                        "backdrops": [image_info("backdrop.png", 96, 64)],
                        "logos": [],
                    },
                    "credits": {"cast": [], "crew": []},
                    "releases": {"countries": []},
                    "videos": {"results": []},
                }
            else:
                self.send_error(404)
                return

            self.send_body(json.dumps(result).encode(), "application/json")

        def send_body(self, body, content_type):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()


def image_info(name, width, height):
    return {
        "file_path": "/" + name,
        "width": width,
        "height": height,
        "aspect_ratio": width / height,
        "iso_639_1": None,
        "vote_average": 5,
        "vote_count": 1,
    }


class Api:
    def __init__(self):
        self.token = ""
        self.user = ""

    def request(self, path, payload=None, method=None):
        authorization = (
            'MediaBrowser Client="artwork-test", Device="test", DeviceId="test", Version="1"'
        )
        if self.token:
            authorization += f', Token="{self.token}"'
        request = Request(
            "http://127.0.0.1:8096/" + path,
            data=None if payload is None else json.dumps(payload).encode(),
            method=method,
            headers={"Authorization": authorization, "Content-Type": "application/json"},
        )
        with urlopen(request, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else None

    def bootstrap(self):
        user = self.request("Startup/User")
        self.request("Startup/Complete", method="POST")
        auth = self.request("Users/AuthenticateByName", {"Username": user["Name"], "Pw": ""})
        self.token = auth["AccessToken"]
        self.user = auth["User"]["Id"]

    def scan(self):
        def scan_task():
            return next(
                task for task in self.request("ScheduledTasks") if task["Key"] == "RefreshLibrary"
            )

        previous = scan_task().get("LastExecutionResult")
        self.request("Library/Refresh", method="POST")
        wait_for(
            lambda: (
                scan_task()["State"] == "Idle"
                and scan_task().get("LastExecutionResult") != previous
            ),
            "library scan completion",
        )
        assert scan_task()["LastExecutionResult"]["Status"] == "Completed"

    def images(self, item_id):
        return self.request(f"Items/{item_id}/Images")


def wait_for(predicate, description):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError(f"Timed out waiting for {description}")


def add_movie(fixtures, title):
    directory = Path("/srv/movies") / title
    directory.mkdir()
    movie = directory / f"{title}.mkv"
    shutil.copyfile(fixtures / "movie.mkv", movie)
    os.utime(movie, (time.time() - 3600, time.time() - 3600))
    nfo = ET.Element("movie")
    ET.SubElement(nfo, "title").text = title
    ET.SubElement(nfo, "uniqueid", {"type": "tmdb", "default": "true"}).text = "9595"
    ET.ElementTree(nfo).write(directory / "movie.nfo")
    directory.chmod(0o777)
    return movie


def image_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(fixtures):
    api = Api()
    api.bootstrap()
    movies = {title: add_movie(fixtures, title) for title in ["Missing", "Custom", "Unchanged"]}
    shutil.copyfile(fixtures / "custom.png", movies["Custom"].parent / "poster.png")
    api.request(
        "Library/VirtualFolders?" + urlencode({"name": "Movies", "collectionType": "movies"}),
        {
            "LibraryOptions": {
                "PathInfos": [{"Path": "/srv/movies"}],
                "EnableRealtimeMonitor": False,
                "SaveLocalMetadata": True,
                "MetadataSavers": [],
                "TypeOptions": [
                    {
                        "Type": "Movie",
                        "MetadataFetchers": [],
                        "ImageFetchers": ["TheMovieDb"],
                        "ImageOptions": [
                            {"Type": "Primary", "Limit": 1, "MinWidth": 0},
                            {"Type": "Backdrop", "Limit": 1, "MinWidth": 0},
                            {"Type": "Logo", "Limit": 0},
                            {"Type": "Thumb", "Limit": 0},
                        ],
                    }
                ],
            }
        },
    )
    api.scan()
    items = api.request("Items?Recursive=true&IncludeItemTypes=Movie&Fields=Path")["Items"]
    ids = {Path(item["Path"]).stem: item["Id"] for item in items}
    assert set(ids) == set(movies), items
    images = {
        title: {image["ImageType"]: Path(image["Path"]) for image in api.images(ids[title])}
        for title in movies
    }
    for title in movies:
        assert {"Primary", "Backdrop"} <= images[title].keys(), (title, images[title])
    custom_hash = image_hash(images["Custom"]["Primary"])
    unchanged_hash = image_hash(images["Unchanged"]["Primary"])

    for title in ["Missing", "Custom"]:
        images[title]["Backdrop"].unlink()
        if title == "Missing":
            images[title]["Primary"].unlink()
        # A replacement at the same path retains the existing Jellyfin item.
        replacement = movies[title].with_suffix(".replacement")
        shutil.copyfile(fixtures / "movie.mkv", replacement)
        replacement.replace(movies[title])

    api.scan()
    recovered = all(
        {"Primary", "Backdrop"} <= {image["ImageType"] for image in api.images(ids[title])}
        for title in ["Missing", "Custom"]
    )
    assert image_hash(images["Custom"]["Primary"]) == custom_hash
    assert image_hash(images["Unchanged"]["Primary"]) == unchanged_hash
    print(f"Ordinary scan recovered replacement artwork: {recovered}", flush=True)

    # Positive control: prove the same provider can restore the deleted images.
    for title in ["Missing", "Custom"]:
        api.request(f"Items/{ids[title]}/Refresh?ImageRefreshMode=FullRefresh", method="POST")
        wait_for(
            lambda item_id=ids[title]: (
                {"Primary", "Backdrop"} <= {image["ImageType"] for image in api.images(item_id)}
            ),
            f"explicit image refresh for {title}",
        )
    assert image_hash(images["Custom"]["Primary"]) == custom_hash
    api.scan()
    assert image_hash(images["Custom"]["Primary"]) == custom_hash
    assert recovered, (
        "Replacing a movie left artwork missing; an explicit image refresh restored it"
    )


if __name__ == "__main__":
    action, fixture_directory = sys.argv[1:]
    if action == "serve":
        serve(Path(fixture_directory))
    else:
        check(Path(fixture_directory))
