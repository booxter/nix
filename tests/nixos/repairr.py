# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.
import json
import shlex
from pathlib import PurePosixPath

REPAIRR = "http://127.0.0.1:8790"
UNFINISHED_ALBUM = f"{REPAIRR}/api/jobs?service=lidarr&view=activity&q=Unfinished"
MEDIA = PurePosixPath("/var/lib/repairr-test-media")
VIDEO = str(MEDIA / "Example.Movie.2026/movie.mkv")


def read_json(url):
    return json.loads(machine.succeed(f"curl -fsS {shlex.quote(url)}"))


def wait_for_job(listing):
    """Return the job when it first appears in this filtered list."""
    command = f"curl -fsS {shlex.quote(listing)} | jq -ce 'select(length == 1) | first'"
    return json.loads(machine.wait_until_succeeds(command, timeout=60))


machine.start()
machine.wait_for_unit("repairr.service")

with subtest("an unfinished album appears in the operator activity page"):
    album = wait_for_job(UNFINISHED_ALBUM)
    assert (
        album["title"] == "Unfinished album download" and album["reasonCode"] == "queue_not_ready"
    ), album
    assert set(album["findings"]) == {
        "incomplete_download",
        "unsupported_queue_state",
        "missing_output_path",
        "missing_album_id",
        "missing_artist_id",
    }, album
    page = machine.succeed(f"curl -fsS '{REPAIRR}/activity?service=lidarr'")
    assert album["title"] in page and "Queue not ready" in page

with subtest("Repairr imports the movie and confirms it from Radarr history"):
    # Radarr publishes the new history entry only after receiving the command.
    movie = wait_for_job(f"{REPAIRR}/api/jobs?service=radarr&state=importing")
    detail = f"{REPAIRR}/api/jobs/{movie['id']}"
    machine.succeed("touch /run/radarr-fixture/publish-import")
    imported = wait_for_job(f"{REPAIRR}/api/jobs?service=radarr&state=imported")
    assert imported["id"] == movie["id"], imported

    (command,) = read_json("http://127.0.0.1:7878/fixture/imports")
    (source,) = command["files"]
    assert command["name"] == "ManualImport" and source["path"] == VIDEO, command
    (attempt,) = read_json(detail)["attempts"]
    (movie_file,) = attempt["receipt"]["files"]
    assert movie_file["droppedPath"] == VIDEO and movie_file["movieId"] == 42, movie_file
    assert movie_file["historyId"] == 51 and movie_file["movieFileId"] == 8, movie_file

with subtest("Lidarr reads the staged tracks and Repairr waits for both history records"):
    album_job = wait_for_job(f"{REPAIRR}/api/jobs?service=lidarr&state=importing")
    album_url = f"{REPAIRR}/api/jobs/{album_job['id']}"
    # The fixture has copied both files, but has published only the first in history.
    machine.wait_until_succeeds("test -e /run/lidarr-fixture/command-checked", timeout=60)
    (pending,) = read_json(album_url)["attempts"]
    assert pending["state"] == "importing" and "receipt" not in pending, pending

    (command,) = read_json("http://127.0.0.1:8687/fixture/imports")
    paths = [PurePosixPath(file["path"]) for file in command["files"]]
    assert sorted(path.name for path in paths) == ["01.flac", "02.flac"], command
    for path in paths:
        assert path.is_relative_to(MEDIA / ".media-repair/workspaces"), path
        machine.succeed(
            f"cmp {MEDIA}/Example.Album/{path.name} /run/lidarr-fixture/library/{path.name}"
        )

    machine.succeed("touch /run/lidarr-fixture/publish-second-track")
    imported = wait_for_job(f"{REPAIRR}/api/jobs?service=lidarr&state=imported")
    assert imported["id"] == album_job["id"], imported
    (album_attempt,) = read_json(album_url)["attempts"]
    tracks = album_attempt["receipt"]["files"]
    assert sorted((row["trackId"], row["historyId"]) for row in tracks) == [
        (11, 92),
        (12, 91),
    ], album_attempt

with subtest("the service user can reopen saved jobs with the media services offline"):
    assert machine.succeed("stat -c %U /var/lib/repairr/jobs.db").strip() == "media-repair-worker"
    machine.succeed("systemctl stop nginx.service", "systemctl restart repairr.service")
    machine.wait_until_succeeds(f"curl -fsS {REPAIRR}/health")
    assert read_json(UNFINISHED_ALBUM) == [album]
    assert read_json(detail)["attempts"] == [attempt]
    assert read_json(album_url)["attempts"] == [album_attempt]

machine.fail("systemctl is-active radarr-repair-controller.timer")
machine.fail("systemctl is-active lidarr-repair-controller.timer")
machine.fail("systemctl is-active media-repair-worker.service")
