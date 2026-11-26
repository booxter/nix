# ruff: noqa: F821
# The NixOS test driver supplies the VMs and subtest.
import html
import json
import re
import shlex

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


def plan_with_repairs_paused(vm):
    vm.wait_for_open_port(7878)
    vm.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    vm.succeed(f"touch {PAUSE}", "systemctl start repairr.service")
    # Follow the same job across restarts and after it leaves the queue.
    link = wait_for_movie(vm, "ready", "Example Movie")
    match = re.search(r'href="(/jobs/\d+)"', link)
    assert match, link
    return REPAIRR + match[1]


def submitted_imports(vm):
    return json.loads(vm.succeed("curl -fsS http://127.0.0.1:7878/fixture/imports"))


def confirm_from_history(vm, job_url):
    vm.succeed(f"touch {FIXTURE}/publish-import")
    wait_for_text(vm, job_url, "Attempt 1 · imported")
    detail = vm.succeed(f"curl -fsS {job_url}")
    (raw_receipt,) = re.findall(r"<pre>(.*?)</pre>", detail, flags=re.DOTALL)
    receipt = json.loads(html.unescape(raw_receipt))
    assert receipt["HistoryID"] == 51 and receipt["MovieFileID"] == 8, receipt
    assert receipt["DroppedPath"] == VIDEO and receipt["MovieID"] == 42, receipt
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
