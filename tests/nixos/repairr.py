# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.
import json
import shlex
from datetime import datetime
from pathlib import PurePosixPath

REPAIRR = "http://127.0.0.1:8790"
UNFINISHED_ALBUM = f"{REPAIRR}/api/jobs?service=lidarr&view=activity&q=Unfinished"
MEDIA = PurePosixPath("/var/lib/repairr-test-media")
VIDEO = str(MEDIA / "Example.Movie.2026/movie.mkv")


def read_json(url):
    return json.loads(machine.succeed(f"curl -fsS {shlex.quote(url)}"))


def wait_for_job(listing, condition="true"):
    """Return the job when it first appears in this filtered list."""
    select = shlex.quote(f"map(select({condition})) | select(length == 1) | first")
    command = f"curl -fsS {shlex.quote(listing)} | jq -ce {select}"
    return json.loads(machine.wait_until_succeeds(command, timeout=60))


def browser_page(path):
    # The operator pages load their data from the API after navigation.
    return machine.succeed(
        "chromium --headless --no-sandbox --disable-dev-shm-usage --disable-gpu "
        f"--virtual-time-budget=5000 --dump-dom {shlex.quote(REPAIRR + path)} 2>/dev/null"
    )


def check_imported_files_page(job_id, files):
    page = browser_page(f"/jobs/{job_id}")
    assert "Next retry" not in page, page
    assert f"Imported files ({len(files)})" in page, page
    assert "Source path" in page and "Library path" in page, page
    for file in files:
        assert file["droppedPath"] in page and file["importedPath"] in page, file


machine.start()
machine.wait_for_unit("repairr.service")

with subtest("both apps wait and retry when the planner returns"):
    waiting_jobs = {}
    deadlines = []
    for service, port in [("radarr", 7878), ("lidarr", 8687)]:
        job = wait_for_job(
            f"{REPAIRR}/api/jobs?service={service}&state=observed",
            '.reasonCode == "planner_retry_scheduled"',
        )
        waiting_jobs[service] = job["id"]
        detail = read_json(f"{REPAIRR}/api/jobs/{job['id']}")
        assert detail["reasonCode"] == "planner_retry_scheduled", detail
        assert detail["attempts"] == [], detail
        deadlines.append(detail["retryAt"])
        page = browser_page(f"/jobs/{job['id']}")
        assert "Planner retry scheduled" in page and "Next retry" in page, page
        assert f'datetime="{detail["retryAt"]}"' in page, page
        assert read_json(f"http://127.0.0.1:{port}/fixture/imports") == []

    # Give the scheduler time to run with a healthy planner before the retry is due.
    machine.succeed("rm /run/repairr-planner-unavailable", "sleep 6")
    for job_id in waiting_jobs.values():
        detail = read_json(f"{REPAIRR}/api/jobs/{job_id}")
        assert detail["state"] == "observed" and detail["attempts"] == [], detail

    # One guest clock serves both jobs. Advance to the later of their deadlines.
    last_retry = max(deadlines, key=datetime.fromisoformat)
    machine.succeed(shlex.join(["date", "-s", last_retry]))

with subtest("Radarr and Lidarr get time to finish their own pending imports"):
    for service in waiting_jobs:
        wait_for_job(f"{REPAIRR}/api/jobs?service={service}&state=ready")

    # The planner has recovered. Let the scheduler run with both plans ready.
    machine.succeed("sleep 6")
    for job_id in waiting_jobs.values():
        detail = read_json(f"{REPAIRR}/api/jobs/{job_id}")
        assert detail["state"] == "ready" and detail["attempts"] == [], detail

with subtest("Repairr restarts with a saved movie plan and a saved album plan"):
    # Let both grace periods expire while Repairr is stopped. A new planning
    # request would receive 503, so either import needs its saved decision.
    machine.succeed(
        "systemctl stop repairr.service",
        "touch /run/repairr-planner-unavailable",
        "date -s '+15 minutes'",
        "systemctl start repairr.service",
    )
    machine.wait_until_succeeds(f"curl -fsS {REPAIRR}/health")

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
    page = browser_page("/activity?service=lidarr")
    assert album["title"] in page and "Queue not ready" in page

with subtest("Repairr imports the movie and confirms it from Radarr history"):
    # Radarr publishes the new history entry only after receiving the command.
    movie = wait_for_job(f"{REPAIRR}/api/jobs?service=radarr&state=importing")
    assert movie["id"] == waiting_jobs["radarr"], movie
    detail = f"{REPAIRR}/api/jobs/{movie['id']}"
    machine.succeed("touch /run/radarr-fixture/publish-import")
    imported = wait_for_job(f"{REPAIRR}/api/jobs?service=radarr&state=imported")
    assert imported["id"] == movie["id"], imported

    (command,) = read_json("http://127.0.0.1:7878/fixture/imports")
    (source,) = command["files"]
    assert command["name"] == "ManualImport" and source["path"] == VIDEO, command
    completed = read_json(detail)
    assert "retryAt" not in completed, completed
    assert completed.get("reasonCode") != "planner_retry_scheduled", completed
    (attempt,) = completed["attempts"]
    (movie_file,) = attempt["receipt"]["files"]
    assert movie_file["droppedPath"] == VIDEO and movie_file["movieId"] == 42, movie_file
    assert movie_file["historyId"] == 51 and movie_file["movieFileId"] == 8, movie_file
    check_imported_files_page(movie["id"], [movie_file])

with subtest("Lidarr reads the staged tracks and Repairr waits for both history records"):
    album_job = wait_for_job(f"{REPAIRR}/api/jobs?service=lidarr&state=importing")
    assert album_job["id"] == waiting_jobs["lidarr"], album_job
    album_url = f"{REPAIRR}/api/jobs/{album_job['id']}"
    # The fixture has copied both files, but has published only the first in history.
    machine.wait_until_succeeds("test -e /run/lidarr-fixture/command-checked", timeout=60)
    (pending,) = read_json(album_url)["attempts"]
    assert pending["state"] == "importing" and "receipt" not in pending, pending

    machine.succeed("touch /run/lidarr-fixture/publish-second-track")
    imported = wait_for_job(f"{REPAIRR}/api/jobs?service=lidarr&state=imported")
    assert imported["id"] == album_job["id"], imported

    (command,) = read_json("http://127.0.0.1:8687/fixture/imports")
    paths = [PurePosixPath(file["path"]) for file in command["files"]]
    assert sorted(path.name for path in paths) == ["01.flac", "02.flac"], command
    for path in paths:
        assert path.is_relative_to(MEDIA / ".media-repair/workspaces"), path
        machine.succeed(
            f"cmp {MEDIA}/Example.Album/{path.name} /run/lidarr-fixture/library/{path.name}"
        )

    (album_attempt,) = read_json(album_url)["attempts"]
    tracks = album_attempt["receipt"]["files"]
    assert sorted((row["trackId"], row["historyId"]) for row in tracks) == [
        (11, 92),
        (12, 91),
    ], album_attempt
    check_imported_files_page(album_job["id"], tracks)

    # Each app made one failed request during the outage and one successful
    # request before restart. Count rejected requests as well as successful ones.
    planner_log = machine.succeed("journalctl -b -u media-repair-planner.service -o cat")
    for service in waiting_jobs:
        requests = [line for line in planner_log.splitlines() if f'"POST /{service}/plan ' in line]
        assert len(requests) == 2, requests

with subtest("the service user can reopen saved jobs with the media services offline"):
    assert machine.succeed("stat -c %U /var/lib/repairr/jobs.db").strip() == "media-repair-worker"
    machine.succeed("systemctl stop nginx.service", "systemctl restart repairr.service")
    machine.wait_until_succeeds(f"curl -fsS {REPAIRR}/health")
    (reopened_album,) = read_json(UNFINISHED_ALBUM)
    assert (reopened_album["id"], reopened_album["findings"]) == (album["id"], album["findings"])
    assert read_json(detail)["attempts"] == [attempt]
    assert read_json(album_url)["attempts"] == [album_attempt]

machine.fail("systemctl is-active radarr-repair-controller.timer")
machine.fail("systemctl is-active lidarr-repair-controller.timer")
machine.fail("systemctl is-active media-repair-worker.service")
