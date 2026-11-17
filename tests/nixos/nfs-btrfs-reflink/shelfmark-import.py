"""Queue test torrents through Shelfmark's HTTP API and verify imported files."""

import json
import os
import time
from pathlib import Path
from urllib.request import Request, urlopen


def request(path: str, payload: dict[str, str] | None = None):
    data = None if payload is None else json.dumps(payload).encode()
    query = Request(
        f"http://127.0.0.1:8084/api/{path}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(query, timeout=10) as response:
        return json.load(response)


def import_download(content_type: str, suffix: str, library: str) -> str:
    task_id = f"reflink-{suffix}"
    queued = request(
        "releases/download",
        {
            "source": "prowlarr",
            "source_id": task_id,
            "title": f"Reflink test {suffix}",
            "author": "Test author",
            "format": suffix,
            "content_type": content_type,
        },
    )
    assert queued["status"] == "queued", queued
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        status = request("status")
        assert task_id not in status.get("error", {}), status
        if task_id in status.get("complete", {}):
            break
        time.sleep(1)
    else:
        raise AssertionError(f"Import timed out: {status}")

    source = Path("/mnt/media/torrents/shelfmark") / f"source.{suffix}"
    destinations = list((Path("/mnt/media/library") / library).rglob(f"*.{suffix}"))
    assert len(destinations) == 1, destinations
    destination = destinations[0]
    assert source.read_bytes() == destination.read_bytes()
    assert not source.samefile(destination)
    with destination.open("rb") as stream:
        os.fsync(stream.fileno())
    return str(destination)


def main() -> None:
    destinations = [
        import_download("book (fiction)", "epub", "books"),
        import_download("audiobook", "m4b", "audiobooks"),
    ]
    Path("/tmp/shelfmark-results.json").write_text(json.dumps(destinations))


if __name__ == "__main__":
    main()
