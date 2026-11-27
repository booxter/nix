# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.
import json
import shlex

REPAIRR = "http://127.0.0.1:8790"
ALBUMS = f"{REPAIRR}/api/jobs?service=lidarr&view=activity"
VIDEO = "/var/lib/repairr-test-media/Example.Movie.2026/movie.mkv"


def read_json(url):
    return json.loads(machine.succeed(f"curl -fsS {shlex.quote(url)}"))


def wait_for_job(listing):
    """Return the job when it first appears in this filtered list."""
    command = f"curl -fsS {shlex.quote(listing)} | jq -ce 'select(length == 1) | first'"
    return json.loads(machine.wait_until_succeeds(command, timeout=60))


machine.start()
machine.wait_for_unit("repairr.service")

with subtest("an unfinished album appears in the operator activity page"):
    album = wait_for_job(ALBUMS)
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
    receipt = attempt["receipt"]
    assert receipt["DroppedPath"] == VIDEO and receipt["MovieID"] == 42, receipt
    assert receipt["HistoryID"] == 51 and receipt["MovieFileID"] == 8, receipt

with subtest("the service user can reopen saved jobs with the media services offline"):
    assert machine.succeed("stat -c %U /var/lib/repairr/jobs.db").strip() == "media-repair-worker"
    machine.succeed("systemctl stop nginx.service", "systemctl restart repairr.service")
    machine.wait_until_succeeds(f"curl -fsS {REPAIRR}/health")
    assert read_json(ALBUMS) == [album]
    assert read_json(detail)["attempts"] == [attempt]

machine.fail("systemctl is-active radarr-repair-controller.timer")
machine.fail("systemctl is-active lidarr-repair-controller.timer")
machine.fail("systemctl is-active media-repair-worker.service")
