"""Exercise Arr manual imports through the running services' public APIs."""

import json
import os
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def request(path: str, payload=None, *, method: str | None = None):
    data = None if payload is None else json.dumps(payload).encode()
    query = Request(
        f"http://127.0.0.1:7878/api/v3/{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "X-Api-Key": "reflink-test-api-key"},
    )
    try:
        with urlopen(query, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        raise AssertionError(f"{path}: {error.code}: {error.read().decode()}") from error


def wait_for_command(command_id: int) -> None:
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        command = request(f"command/{command_id}")
        assert command["status"] != "failed", command
        if command["status"] == "completed":
            return
        time.sleep(1)
    raise AssertionError(f"Command timed out: {command}")


def main() -> None:
    library = "/mnt/media/library/movies"
    source = Path("/mnt/media/torrents/radarr/Reflink Movie (2020).mkv")
    request("rootfolder", {"path": library})
    profiles = request("qualityprofile")
    movie = request(
        "movie",
        {
            "title": "Reflink Movie",
            "tmdbId": 1,
            "qualityProfileId": profiles[0]["id"],
            "rootFolderPath": library,
            "monitored": False,
            "minimumAvailability": "released",
            "addOptions": {"searchForMovie": False},
        },
    )
    media_management = request("config/mediamanagement")
    media_management["copyUsingHardlinks"] = True
    media_management["setPermissionsLinux"] = True
    media_management["chmodFolder"] = "777"
    request("config/mediamanagement", media_management, method="PUT")
    command = request(
        "command",
        {
            "name": "ManualImport",
            "importMode": "copy",
            "files": [
                {
                    "path": str(source),
                    "movieId": movie["id"],
                    "quality": {"quality": {"id": 4}, "revision": {"version": 1}},
                    "languages": [{"id": 1, "name": "English"}],
                }
            ],
        },
    )
    wait_for_command(command["id"])
    files = request(f"moviefile?movieId={movie['id']}")
    assert len(files) == 1, files
    destination = Path(files[0]["path"])
    assert source.read_bytes() == destination.read_bytes()
    assert not source.samefile(destination)
    with destination.open("rb") as stream:
        os.fsync(stream.fileno())
    Path("/tmp/arr-results.json").write_text(json.dumps([str(destination)]))


if __name__ == "__main__":
    main()
