# ruff: noqa: F821
# The NixOS test driver supplies the VMs and subtest.
import html
import json
import re
import shlex
from pathlib import PurePosixPath
from urllib.parse import urlencode

from lxml.html import fromstring

COMPLETED_QUEUE_ID = 101
UNFINISHED_QUEUE_ID = 102
VIDEO = "/var/lib/repairr-pipeline/Example.Movie.2026/movie.mkv"
PAUSE = "/run/pause-radarr-repairs"
FIXTURE = "/run/radarr-fixture"
REPAIRR = "http://127.0.0.1:8790"


def collect_queue(vm):
    output = vm.succeed("repairr --collect-radarr --config /etc/repairr.json")
    reports = [json.loads(line) for line in output.splitlines()]
    ids = sorted(report["queue_id"] for report in reports)
    assert ids == [COMPLETED_QUEUE_ID, UNFINISHED_QUEUE_ID], reports
    return {report["queue_id"]: report for report in reports}


def assert_fixture_video(video):
    assert video["path_components"] == ["movie.mkv"], video
    probe = video["probe"]
    assert probe["status"] == "ok", probe
    widths = [stream["width"] for stream in probe["streams"] if stream["kind"] == "video"]
    assert widths == [64], probe


def wait_for_text(vm, url, text):
    return vm.wait_until_succeeds(
        f"curl -fsS {shlex.quote(url)} | grep -F -- {shlex.quote(text)}", timeout=60
    )


def wait_for_movie(vm, state, text):
    return wait_for_text(vm, f"{REPAIRR}/activity?service=radarr&state={state}", text)


def wait_for_job(vm, listing_url, title):
    link = wait_for_text(vm, listing_url, title)
    match = re.search(r'href="(/jobs/\d+)"', link)
    assert match, link
    return REPAIRR + match[1]


def plan_with_repairs_paused(vm, service="radarr", title="Example Movie"):
    vm.wait_for_open_port(7878)
    vm.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    vm.succeed(f"touch /run/pause-{service}-repairs", "systemctl start repairr.service")
    # Follow the same job across restarts and after it leaves the queue.
    return wait_for_job(vm, f"{REPAIRR}/activity?service={service}&state=ready", title)


def choice_request(vm, job_url, options, selected):
    # Use the form and cookie from the restarted daemon, just as an operator
    # would after reopening the job. Hidden fields identify this case revision.
    cookies = "/tmp/repairr-operator.cookies"
    page = vm.succeed(f"curl -fsS -c {cookies} {job_url}")
    (form,) = fromstring(page, base_url=job_url).forms
    choices = {
        option.text_content(): option.get("value")
        for option in form.xpath('.//select[@name="selection"]/option')
        if option.get("value")
    }
    assert set(choices) == set(options), choices
    form.fields["selection"] = choices[selected]
    return shlex.join(
        [
            "curl",
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "-b",
            cookies,
            "-H",
            "Sec-Fetch-Site: same-origin",
            "--data",
            urlencode(form.form_values()),
            form.action,
        ]
    )


def submitted_imports(vm):
    return json.loads(vm.succeed("curl -fsS http://127.0.0.1:7878/fixture/imports"))


def import_receipt(vm, job_url):
    wait_for_text(vm, job_url, "Attempt 1 · imported")
    detail = vm.succeed(f"curl -fsS {job_url}")
    (raw_receipt,) = re.findall(r"<pre>(.*?)</pre>", detail, flags=re.DOTALL)
    return json.loads(html.unescape(raw_receipt))


def confirm_from_history(vm, job_url, expected_path=VIDEO):
    vm.succeed(f"touch {FIXTURE}/publish-import")
    receipt = import_receipt(vm, job_url)
    assert receipt["HistoryID"] == 51 and receipt["MovieFileID"] == 8, receipt
    assert receipt["DroppedPath"] == expected_path and receipt["MovieID"] == 42, receipt
    assert receipt["DownloadID"] == "SABnzbd_nzo_complete", receipt
    assert len(submitted_imports(vm)) == 1


machine.start()
machine.wait_for_open_port(7878)
reports = collect_queue(machine)

with subtest("the planner can select the completed movie for manual import"):
    case = reports[COMPLETED_QUEUE_ID]["case"]
    movie = case["radarr"]["movie"]
    assert movie["title"] == "Example Movie", movie
    assert movie["radarr_id"] == 42 and movie["tmdb_id"] == 123456, movie

    (video,) = case["files"]
    assert_fixture_video(video)
    # The offered import must refer to the same file the helper inspected.
    offered_files = {
        option["file_id"]
        for option in case["capabilities"]
        if option["action"] == "manual_import_file_v1"
    }
    assert video["file_id"] in offered_files, case["capabilities"]

with subtest("the planner case keeps the local path and download-client ID private"):
    planner_input = json.dumps(reports[COMPLETED_QUEUE_ID]["case"])
    assert "/var/lib/repairr-pipeline" not in planner_input
    assert "SABnzbd_nzo_complete" not in planner_input

with subtest("the unfinished download reports problems from both Radarr and SABnzbd"):
    unfinished = reports[UNFINISHED_QUEUE_ID]
    # Radarr still lists the download as active, and SABnzbd has no history for it.
    expected = {"incomplete_download", "unsupported_queue_state", "download_not_found"}
    assert set(unfinished["findings"]) == expected, unfinished
    assert "case" not in unfinished, unfinished

with subtest("the selected file is confirmed only when Radarr reports a new import"):
    job = plan_with_repairs_paused(machine)
    assert submitted_imports(machine) == []
    machine.succeed(f"rm {PAUSE}")
    wait_for_movie(machine, "importing", "Example Movie")
    # The command received by Radarr shows exactly what passed authorization.
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:7878/fixture/imports | grep -F ManualImport"
    )
    (command,) = submitted_imports(machine)
    assert command["name"] == "ManualImport" and command["importMode"] == "copy", command
    (selected,) = command["files"]
    assert (selected["path"], selected["movieId"], selected["downloadId"]) == (
        VIDEO,
        42,
        "SABnzbd_nzo_complete",
    ), selected
    wait_for_text(machine, job, "Import command #1")
    machine.wait_until_succeeds(f"test -e {FIXTURE}/history-checked")
    wait_for_text(machine, job, "Attempt 1 · importing")

with subtest("a fresh poll finds a new movie while the first waits for import history"):
    # Restart to poll immediately. Radarr still lists the first movie, but
    # its source has gone away and only import history can confirm it now.
    machine.succeed(
        "systemctl stop repairr.service", f"rm {VIDEO}", "systemctl start repairr.service"
    )
    wait_for_text(machine, f"{REPAIRR}/activity?service=radarr&q=New+Movie", "Waiting for download")
    detail = machine.succeed(f"curl -fsS {job}")
    assert "Attempt 1 · importing" in detail and "Inspection error" not in detail, detail
    confirm_from_history(machine, job)
    machine.shutdown()

with subtest("a same-size replacement blocks the saved plan before Radarr receives a command"):
    replaced.start()
    plan_with_repairs_paused(replaced)
    # A new inode with identical bytes and timestamps isolates the identity change.
    original = replaced.succeed(f"stat -c '%i %s %Y' {VIDEO}").split()
    replaced.succeed(f"cp -p {VIDEO} {VIDEO}.new && mv -T {VIDEO}.new {VIDEO}")
    replacement = replaced.succeed(f"stat -c '%i %s %Y' {VIDEO}").split()
    assert original[0] != replacement[0] and original[1:] == replacement[1:]
    replaced.succeed(f"rm {PAUSE}")
    wait_for_movie(replaced, "blocked", "selected file changed after planning")
    assert submitted_imports(replaced) == []
    assert replaced.succeed(f"stat -c '%i %s %Y' {VIDEO}").split() == replacement
    replaced.shutdown()

with subtest("the scan and pre-import recheck both report a missing movie"):
    missingMovie.start()
    plan_with_repairs_paused(missingMovie)
    missingMovie.succeed(f"touch {FIXTURE}/missing-movie")
    report = collect_queue(missingMovie)[COMPLETED_QUEUE_ID]
    assert report["findings"] == ["missing_movie_id"] and "case" not in report, report

    missingMovie.succeed(f"rm {PAUSE}")
    wait_for_movie(missingMovie, "blocked", "missing_movie_id")
    assert submitted_imports(missingMovie) == []
    missingMovie.shutdown()

with subtest("a lost command response is recovered from history after restart"):
    lostResponse.start()
    job = plan_with_repairs_paused(lostResponse)
    lostResponse.succeed(f"touch {FIXTURE}/drop-reply", f"rm {PAUSE}")
    wait_for_text(lostResponse, job, "checking history without resubmitting")
    assert len(submitted_imports(lostResponse)) == 1

    # Keep fake Radarr running so it counts submissions across both processes.
    # Clearing the marker while Repairr is stopped proves the next history
    # lookup comes from the new process, with the receipt still withheld.
    lostResponse.succeed("systemctl stop repairr.service", f"rm {FIXTURE}/history-checked")
    lostResponse.succeed("systemctl start repairr.service")
    lostResponse.wait_until_succeeds(f"test -e {FIXTURE}/history-checked", timeout=60)
    wait_for_text(lostResponse, job, "Attempt 1 · importing")
    assert len(submitted_imports(lostResponse)) == 1
    confirm_from_history(lostResponse, job)
    lostResponse.shutdown()

with subtest("an operator can reopen a movie after restart and choose the file to import"):
    fileChoice.start()
    fileChoice.wait_for_open_port(7878)
    fileChoice.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    fileChoice.succeed("systemctl start repairr.service")

    job = wait_for_job(fileChoice, f"{REPAIRR}/radarr", "Example Movie")
    question = "Which file should be used for this movie?"
    wait_for_text(fileChoice, job, question)
    assert submitted_imports(fileChoice) == []

    fileChoice.succeed("systemctl restart repairr.service")
    wait_for_text(fileChoice, job, question)
    assert submitted_imports(fileChoice) == []
    answer = choice_request(fileChoice, job, ["movie.mkv", "theatrical.mkv"], "theatrical.mkv")
    assert fileChoice.succeed(answer) == "303"

    chosen = str(PurePosixPath(VIDEO).with_name("theatrical.mkv"))
    wait_for_text(fileChoice, job, "Import command #1")
    (command,) = submitted_imports(fileChoice)
    (selected,) = command["files"]
    assert selected["path"] == chosen, command
    confirm_from_history(fileChoice, job, chosen)
    fileChoice.shutdown()


with subtest("Lidarr confirms the album only after both selected tracks appear in history"):
    albumImport.start()
    job = plan_with_repairs_paused(albumImport, "lidarr", "Example Album")
    albumImport.succeed("rm /run/pause-lidarr-repairs")

    # The fixture returns a completed command and history for just 01.flac.
    # Wait for Repairr to record that it checked both before releasing 02.flac.
    wait_for_text(albumImport, job, "waiting for import history")
    wait_for_text(albumImport, job, "Attempt 1 · importing")
    albumImport.succeed("touch /run/lidarr-fixture/publish-second-track")
    receipt = import_receipt(albumImport, job)

    (command,) = submitted_imports(albumImport)
    assert command["name"] == "ManualImport" and command["importMode"] == "copy", command
    expected = {"01.flac": 12, "02.flac": 11}
    assert len(command["files"]) == len(expected), command
    selected_paths = {}
    for file in command["files"]:
        path = PurePosixPath(file["path"])
        assert path.is_relative_to("/var/lib/repairr-pipeline/.media-repair/workspaces"), file
        assert (file["artistId"], file["albumId"], file["albumReleaseId"]) == (7, 3, 81), file
        (track_id,) = file["trackIds"]
        assert track_id == expected[path.name], file
        selected_paths[track_id] = str(path)
    assert set(selected_paths) == set(expected.values()), command
    assert (
        len(receipt) == 2 and {r["track_id"]: r["dropped_path"] for r in receipt} == selected_paths
    ), receipt
    albumImport.shutdown()

with subtest("the operator's edition selects the release and tracks imported into Lidarr"):
    releaseChoice.start()
    releaseChoice.wait_for_open_port(7878)
    releaseChoice.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    releaseChoice.succeed("systemctl start repairr.service")
    job = wait_for_job(releaseChoice, f"{REPAIRR}/lidarr", "Example Artist")
    wait_for_text(releaseChoice, job, "Which release should these tracks be imported into?")
    assert submitted_imports(releaseChoice) == []

    original = "Example Album — CD (release 81)"
    reissue = "Example Album Reissue — CD (release 82)"
    answer = choice_request(releaseChoice, job, [original, reissue], reissue)
    assert releaseChoice.succeed(answer) == "303"
    # A second open tab still has the previous revision of the question.
    assert releaseChoice.succeed(answer) == "409"
    releaseChoice.succeed("touch /run/lidarr-fixture/publish-second-track")
    receipt = import_receipt(releaseChoice, job)
    (command,) = submitted_imports(releaseChoice)
    assert [(file["albumReleaseId"], file["trackIds"]) for file in command["files"]] == [
        (82, [21]),
        (82, [22]),
    ], command
    assert {track["track_id"] for track in receipt} == {21, 22}, receipt
    releaseChoice.shutdown()

with subtest("an album that resumes downloading blocks the saved plan before import"):
    unfinishedAlbum.start()
    job = plan_with_repairs_paused(unfinishedAlbum, "lidarr", "Example Album")
    unfinishedAlbum.succeed("touch /run/lidarr-fixture/downloading", "rm /run/pause-lidarr-repairs")

    wait_for_text(unfinishedAlbum, job, "Attempt 1 · blocked")
    wait_for_text(unfinishedAlbum, job, "Lidarr queue item is not eligible for repair")
    assert submitted_imports(unfinishedAlbum) == []

with subtest("a completed library album is declined without an operator question"):
    # Pause automatic cleanup so the declined job stays visible in activity.
    unfinishedAlbum.succeed(
        "systemctl stop repairr.service",
        "rm /run/lidarr-fixture/downloading",
        "touch /run/lidarr-fixture/library-complete /run/pause-lidarr-repairs",
        "systemctl start repairr.service",
    )
    wait_for_text(unfinishedAlbum, job, "There are no missing tracks to import.")
    inbox = unfinishedAlbum.succeed(f"curl -fsS {REPAIRR}/lidarr")
    assert "Example Album" not in inbox
    assert submitted_imports(unfinishedAlbum) == []
