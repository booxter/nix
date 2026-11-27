# ruff: noqa: F821
# The NixOS test driver supplies the VMs and subtest.
import json
import shlex
from pathlib import PurePosixPath
from urllib.parse import urlencode

COMPLETED_QUEUE_ID = 101
UNFINISHED_QUEUE_ID = 102
VIDEO = "/var/lib/repairr-pipeline/Example.Movie.2026/movie.mkv"
PAUSE = "/run/pause-radarr-repairs"
FIXTURE = "/run/radarr-fixture"
REPAIRR = "http://127.0.0.1:8790"
COOKIES = "/tmp/repairr-operator.cookies"


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


def wait_for_json(vm, url, condition):
    """Return the first response that meets the jq condition, including after a restart."""
    select = shlex.quote(f"select({condition})")
    return json.loads(
        vm.wait_until_succeeds(
            f"set -o pipefail; curl -fsS {shlex.quote(url)} | jq -ce {select}", timeout=60
        )
    )


def find_job(vm, service, title, **filters):
    query = urlencode({"service": service, "q": title, **filters})
    (job,) = wait_for_json(vm, f"{REPAIRR}/api/jobs?{query}", "length == 1")
    return f"{REPAIRR}/api/jobs/{job['id']}"


def plan_with_repairs_paused(vm, service="radarr", title="Example Movie"):
    vm.wait_for_open_port(7878)
    vm.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    vm.succeed(f"touch /run/pause-{service}-repairs", "systemctl start repairr.service")
    # Follow the same job across restarts and after it leaves the queue.
    return find_job(vm, service, title, state="ready")


def read_job(vm, url):
    return json.loads(vm.succeed(f"curl -fsS -c {COOKIES} {shlex.quote(url)}"))


def assert_planner_stop(job, code, explanation):
    assert (job["reasonCode"], job["reason"]) == (code, explanation), job


def action_request(url, token, case, **fields):
    body = {"revision": case["revision"], "fingerprint": case["fingerprint"], **fields}
    return shlex.join(
        [
            "curl",
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "-b",
            COOKIES,
            "-H",
            "Sec-Fetch-Site: same-origin",
            "-H",
            "X-CSRF-Token: " + token,
            "--json",
            json.dumps(body),
            url,
        ]
    )


def choice_request(vm, api, options, selected):
    current = read_job(vm, api + "/question")
    choices = {choice["label"]: choice["value"] for choice in current["question"]["choices"]}
    assert set(choices) == set(options), choices
    return action_request(api + "/answer", current["csrfToken"], current, choice=choices[selected])


def submitted_imports(vm):
    return json.loads(vm.succeed("curl -fsS http://127.0.0.1:7878/fixture/imports"))


def restart_after_lost_reply(vm, job, service):
    """Restart Repairr while the media service still has incomplete import history."""
    fixture = f"/run/{service}-fixture"
    history_checked = f"{fixture}/history-checked"

    def check_pending_import():
        vm.wait_until_succeeds(f"test -e {history_checked}", timeout=60)
        detail = read_job(vm, job)
        (attempt,) = detail["attempts"]
        assert detail["state"] == attempt["state"] == "importing", detail
        assert "commandId" not in attempt and "receipt" not in attempt, attempt
        assert len(submitted_imports(vm)) == 1

    vm.succeed(f"touch {fixture}/drop-reply", f"rm /run/pause-{service}-repairs")
    check_pending_import()

    # Keep the media service running so it counts submissions across the restart.
    # Clear the marker while Repairr is stopped so the next check requires a new history read.
    vm.succeed(
        "systemctl stop repairr.service", f"rm {history_checked}", "systemctl start repairr.service"
    )
    check_pending_import()


def retry_after_queue_outage(vm, job, service):
    """Fail the queue recheck after planning, then let the saved plan run again."""
    outage = f"/run/{service}-fixture/queue-unavailable"
    vm.succeed(f"touch {outage}", f"rm /run/pause-{service}-repairs")
    waiting = wait_for_json(vm, job, '.state == "ready" and .attempts[0].state == "failed"')
    (failed,) = waiting["attempts"]
    assert "503" in failed["reason"] and "commandId" not in failed, failed
    assert submitted_imports(vm) == []

    # Passing the retry deadline with the planner offline proves that
    # recovery uses the original decision without operator intervention.
    vm.succeed(
        "systemctl stop scripted-planner.service",
        f"rm {outage}",
        shlex.join(["date", "-s", waiting["retryAt"]]),
    )
    importing = wait_for_json(vm, job, '.state == "importing" and .attempts[1].commandId == 1')
    assert "retryAt" not in importing, importing


def submitted_removals(vm):
    return json.loads(vm.succeed("curl -fsS http://127.0.0.1:7878/fixture/removals"))


def replace_file(vm, path):
    original = vm.succeed(f"stat -c '%i %s %Y' {path}").split()
    vm.succeed(f"cp -p {path} {path}.new && mv -T {path}.new {path}")
    replacement = vm.succeed(f"stat -c '%i %s %Y' {path}").split()
    assert original[0] != replacement[0] and original[1:] == replacement[1:]
    return replacement


def confirmed_files(vm, job_url, attempt_number=1):
    job = wait_for_json(vm, job_url, '.state == "imported"')
    assert len(job["attempts"]) == attempt_number and "question" not in job, job
    attempt = job["attempts"][-1]
    assert attempt["number"] == attempt_number and attempt["state"] == "imported", attempt
    return attempt["receipt"]["files"]


def confirm_from_history(vm, job_url, expected_path=VIDEO, attempt_number=1):
    vm.succeed(f"touch {FIXTURE}/publish-import")
    (movie,) = confirmed_files(vm, job_url, attempt_number)
    assert movie["historyId"] == 51 and movie["movieFileId"] == 8, movie
    assert movie["droppedPath"] == expected_path and movie["movieId"] == 42, movie
    assert movie["downloadId"] == "SABnzbd_nzo_complete", movie
    assert len(submitted_imports(vm)) == 1


def reopen_execution_question(vm, job, kind):
    """Restart with an unanswered attempt and read its question with fresh credentials."""
    stopped = wait_for_json(vm, job, f".question.kind == {json.dumps(kind)}")
    question = stopped["question"]
    assert stopped["attempts"][-1]["question"] == question, stopped
    assert submitted_imports(vm) == []

    vm.succeed("systemctl restart repairr.service")
    vm.wait_for_open_port(8790)
    reopened = read_job(vm, job + "/question")
    assert reopened["question"] == question and reopened["actions"]["answer"], reopened
    return reopened


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
    job = plan_with_repairs_paused(machine)
    unfinished = reports[UNFINISHED_QUEUE_ID]
    # Radarr still lists the download as active, and SABnzbd has no history for it.
    expected = {"incomplete_download", "unsupported_queue_state", "download_not_found"}
    assert set(unfinished["findings"]) == expected, unfinished
    assert "case" not in unfinished, unfinished
    unfinished_job = read_job(machine, find_job(machine, "radarr", "Unfinished Movie"))
    assert set(unfinished_job["findings"]) == expected, unfinished_job
    assert unfinished_job["fingerprint"] == "" and unfinished_job["attempts"] == [], unfinished_job

with subtest("Radarr retries authorization after its queue returns 503"):
    retry_after_queue_outage(machine, job, "radarr")

with subtest("the selected file is confirmed only when Radarr reports a new import"):
    # The command received by Radarr shows exactly what passed authorization.
    (command,) = submitted_imports(machine)
    assert command["name"] == "ManualImport" and command["importMode"] == "copy", command
    (selected,) = command["files"]
    assert (selected["path"], selected["movieId"], selected["downloadId"]) == (
        VIDEO,
        42,
        "SABnzbd_nzo_complete",
    ), selected
    machine.wait_until_succeeds(f"test -e {FIXTURE}/history-checked")
    assert read_job(machine, job)["attempts"][-1]["state"] == "importing"

with subtest("a fresh poll finds a new movie while the first waits for import history"):
    # Restart to poll immediately. Radarr still lists the first movie, but
    # its source has gone away and only import history can confirm it now.
    machine.succeed(
        "systemctl stop repairr.service", f"rm {VIDEO}", "systemctl start repairr.service"
    )
    new_movie = find_job(machine, "radarr", "New Movie")
    assert read_job(machine, new_movie)["reasonCode"] == "incomplete_download"
    detail = read_job(machine, job)
    assert detail["attempts"][-1]["state"] == "importing" and "inspectionError" not in detail, (
        detail
    )
    confirm_from_history(machine, job, attempt_number=2)
    machine.shutdown()

with subtest("a same-size replacement blocks the saved plan before Radarr receives a command"):
    replaced.start()
    job = plan_with_repairs_paused(replaced)
    original_case = read_job(replaced, job)
    assert original_case["actions"]["remove"], original_case
    # A new inode with identical bytes and timestamps isolates the identity change.
    replacement = replace_file(replaced, VIDEO)
    replaced.succeed(f"rm {PAUSE}")
    wait_for_json(replaced, job, '.state == "blocked" and .reasonCode == "evidence_changed"')
    assert submitted_imports(replaced) == []
    assert replaced.succeed(f"stat -c '%i %s %Y' {VIDEO}").split() == replacement

with subtest("a removal confirmation belongs to the file the operator reviewed"):
    # Restart to observe the replacement immediately. Use the new CSRF credentials
    # for both requests so only the case fingerprint distinguishes them.
    replaced.succeed(f"touch {PAUSE}", "systemctl restart repairr.service")
    wait_for_json(replaced, job, '.state == "ready"')
    current_case = read_job(replaced, job)
    assert current_case["actions"]["remove"], current_case
    assert original_case["revision"] == current_case["revision"]
    assert original_case["fingerprint"] != current_case["fingerprint"]
    token = current_case["csrfToken"]

    assert replaced.succeed(action_request(job + "/remove", token, original_case)) == "409"
    queue = "curl -fsS http://127.0.0.1:7878/api/v3/queue"
    assert COMPLETED_QUEUE_ID in [
        row["id"] for row in json.loads(replaced.succeed(queue))["records"]
    ]

with subtest("a failed removal cannot delete a replacement on retry"):
    replaced.succeed(f"touch {FIXTURE}/reject-removal")
    assert replaced.succeed(action_request(job + "/remove", token, current_case)) == "204"
    wait_for_json(replaced, job, '.state == "blocked" and .pendingAction == "delete"')
    assert submitted_removals(replaced) == [COMPLETED_QUEUE_ID]

    # Restart to observe the replacement before the retry. The latest case
    # now differs from the approval saved alongside the failed request.
    replaced.succeed("systemctl stop repairr.service")
    replacement = replace_file(replaced, VIDEO)
    replaced.succeed("systemctl start repairr.service")
    changed = wait_for_json(
        replaced, job, f".fingerprint != {json.dumps(current_case['fingerprint'])}"
    )
    assert changed["pendingAction"] == "delete", changed
    replaced.succeed(f"rm {FIXTURE}/reject-removal", shlex.join(["date", "-s", changed["retryAt"]]))
    assert find_job(replaced, "radarr", "Example Movie", view="inbox") == job
    assert submitted_removals(replaced) == [COMPLETED_QUEUE_ID]
    assert replaced.succeed(f"stat -c '%i %s %Y' {VIDEO}").split() == replacement
    assert COMPLETED_QUEUE_ID in [
        row["id"] for row in json.loads(replaced.succeed(queue))["records"]
    ]

    fresh = read_job(replaced, job)
    assert fresh["pendingAction"] == "confirm_removal", fresh
    assert "retryAt" not in fresh, fresh
    assert fresh["fingerprint"] != current_case["fingerprint"]
    assert replaced.succeed(action_request(job + "/remove", fresh["csrfToken"], fresh)) == "204"
    assert find_job(replaced, "radarr", "Example Movie", state="removed", view="history") == job
    assert submitted_removals(replaced) == [COMPLETED_QUEUE_ID, COMPLETED_QUEUE_ID]
    assert [row["id"] for row in json.loads(replaced.succeed(queue))["records"]] == [
        UNFINISHED_QUEUE_ID
    ]
    replaced.shutdown()

with subtest("the scan and pre-import recheck both report a missing movie"):
    missingMovie.start()
    job = plan_with_repairs_paused(missingMovie)
    missingMovie.succeed(f"touch {FIXTURE}/missing-movie")
    report = collect_queue(missingMovie)[COMPLETED_QUEUE_ID]
    assert report["findings"] == ["missing_movie_id"] and "case" not in report, report

    missingMovie.succeed(f"rm {PAUSE}")
    blocked = wait_for_json(missingMovie, job, '.state == "blocked"')
    assert blocked["reason"] == "missing_movie_id", blocked
    assert submitted_imports(missingMovie) == []
    missingMovie.shutdown()

with subtest("Radarr confirms the movie after its command response is lost and Repairr restarts"):
    lostResponse.start()
    job = plan_with_repairs_paused(lostResponse)
    restart_after_lost_reply(lostResponse, job, "radarr")
    confirm_from_history(lostResponse, job)
    lostResponse.shutdown()

with subtest("an operator can reopen a movie after restart and choose the file to import"):
    fileChoice.start()
    fileChoice.wait_for_open_port(7878)
    fileChoice.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    fileChoice.succeed(f"touch {FIXTURE}/runtime-mismatch", "systemctl start repairr.service")

    job = find_job(fileChoice, "radarr", "Example Movie", view="inbox")
    question = read_job(fileChoice, job)["question"]
    assert question["kind"] == "file", question
    assert submitted_imports(fileChoice) == []

    fileChoice.succeed("systemctl restart repairr.service")
    reopened = wait_for_json(fileChoice, job, ".question != null")
    assert reopened["question"] == question
    assert_planner_stop(
        reopened, "ambiguous_file_selection", "Both videos can be imported. Choose the movie file."
    )
    assert submitted_imports(fileChoice) == []
    answer = choice_request(fileChoice, job, ["movie.mkv", "theatrical.mkv"], "theatrical.mkv")
    assert fileChoice.succeed(answer) == "204"

with subtest("a runtime override after restart imports the file the operator chose"):
    reviewed = reopen_execution_question(fileChoice, job, "runtime")
    question = reviewed["question"]
    assert "Movie runtime: 12 minutes" in question["context"], question
    answer = action_request(
        job + "/answer",
        reviewed["csrfToken"],
        reviewed,
        runtimeMinutes=12,
        guidance="Use the shorter theatrical cut.",
    )
    assert fileChoice.succeed(answer) == "204"

    chosen = str(PurePosixPath(VIDEO).with_name("theatrical.mkv"))
    wait_for_json(fileChoice, job, ".attempts[1].commandId == 1")
    (command,) = submitted_imports(fileChoice)
    (selected,) = command["files"]
    assert selected["path"] == chosen, command
    confirm_from_history(fileChoice, job, chosen, attempt_number=2)
    blocked, imported = read_job(fileChoice, job)["attempts"]
    assert blocked["reasonCode"] == "runtime_mismatch" and blocked["question"] == question, blocked
    assert "reasonCode" not in imported, imported
    fileChoice.shutdown()

with subtest("an interrupted preparation waits for the operator before it tries again"):
    interrupted.start()
    job = plan_with_repairs_paused(interrupted)
    # Hold Radarr's reply to the authorization check so the daemon dies before submission.
    interrupted.succeed("systemctl kill -s STOP repairr-fixture.service", f"rm {PAUSE}")
    wait_for_json(interrupted, job, '.state == "running"')
    interrupted.succeed("systemctl kill -s KILL repairr.service")
    interrupted.wait_until_succeeds("systemctl is-failed repairr.service")
    interrupted.succeed(
        "systemctl kill -s CONT repairr-fixture.service",
        "systemctl start repairr.service",
    )
    reviewed = reopen_execution_question(interrupted, job, "retry")
    answer = action_request(job + "/answer", reviewed["csrfToken"], reviewed)
    assert interrupted.succeed(answer) == "204"
    confirm_from_history(interrupted, job, attempt_number=2)
    interrupted.shutdown()

with subtest("Lidarr retries authorization after its queue returns 503"):
    albumImport.start()
    job = plan_with_repairs_paused(albumImport, "lidarr", "Example Album")
    retry_after_queue_outage(albumImport, job, "lidarr")

with subtest("Lidarr confirms the album only after both selected tracks appear in history"):
    # The fixture returns a completed command and history for just 01.flac.
    # Wait for Repairr to record that it checked both before releasing 02.flac.
    albumImport.wait_until_succeeds("test -e /run/lidarr-fixture/command-checked")
    detail = read_job(albumImport, job)
    assert (
        detail["attempts"][-1]["state"] == "importing" and "receipt" not in detail["attempts"][-1]
    )
    albumImport.succeed("touch /run/lidarr-fixture/publish-second-track")
    files = confirmed_files(albumImport, job, attempt_number=2)

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
    assert len(files) == 2 and {f["trackId"]: f["droppedPath"] for f in files} == selected_paths, (
        files
    )
    albumImport.shutdown()

with subtest("Lidarr confirms both tracks after its command response is lost and Repairr restarts"):
    albumLostResponse.start()
    job = plan_with_repairs_paused(albumLostResponse, "lidarr", "Example Album")
    restart_after_lost_reply(albumLostResponse, job, "lidarr")

    # Only the first track was in history during the restart.
    albumLostResponse.succeed("touch /run/lidarr-fixture/publish-second-track")
    files = confirmed_files(albumLostResponse, job)
    assert sorted((file["trackId"], file["historyId"]) for file in files) == [(11, 92), (12, 91)], (
        files
    )
    assert len(submitted_imports(albumLostResponse)) == 1
    albumLostResponse.shutdown()

with subtest("the operator's edition selects the release and tracks imported into Lidarr"):
    releaseChoice.start()
    releaseChoice.wait_for_open_port(7878)
    releaseChoice.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    releaseChoice.succeed("systemctl start repairr.service")
    job = find_job(releaseChoice, "lidarr", "Example Artist", view="inbox")
    question = read_job(releaseChoice, job)["question"]
    assert question["kind"] == "release", question
    assert submitted_imports(releaseChoice) == []

    releaseChoice.succeed("systemctl restart repairr.service")
    reopened = wait_for_json(releaseChoice, job, ".question != null")
    assert reopened["question"] == question
    assert_planner_stop(
        reopened, "ambiguous_release", "The same songs appear on both editions. Choose a release."
    )
    original = "Example Album — CD (release 81)"
    reissue = "Example Album Reissue — CD (release 82)"
    answer = choice_request(releaseChoice, job, [original, reissue], reissue)
    releaseChoice.wait_for_open_port(443)
    releaseChoice.succeed(shlex.join(["python3", "/etc/choose-release.py", reissue]))
    # A second open tab still has the previous revision of the question.
    assert releaseChoice.succeed(answer) == "409"
    releaseChoice.succeed("touch /run/lidarr-fixture/publish-second-track")
    files = confirmed_files(releaseChoice, job)
    (command,) = submitted_imports(releaseChoice)
    assert [(file["albumReleaseId"], file["trackIds"]) for file in command["files"]] == [
        (82, [21]),
        (82, [22]),
    ], command
    assert {file["trackId"] for file in files} == {21, 22}, files
    releaseChoice.shutdown()

with subtest("an album that resumes downloading blocks the saved plan before import"):
    unfinishedAlbum.start()
    job = plan_with_repairs_paused(unfinishedAlbum, "lidarr", "Example Album")
    unfinishedAlbum.succeed("touch /run/lidarr-fixture/downloading", "rm /run/pause-lidarr-repairs")

    detail = wait_for_json(
        unfinishedAlbum, job, '.state == "blocked" and .reasonCode == "incomplete_download"'
    )
    assert detail["attempts"][0]["state"] == "blocked", detail
    assert submitted_imports(unfinishedAlbum) == []

with subtest("a completed library album is declined without an operator question"):
    # A fresh poll records what is currently preventing inspection.
    unfinishedAlbum.succeed("systemctl restart repairr.service")
    wait_for_json(unfinishedAlbum, job, '.findings == ["incomplete_download"]')

    # Pause automatic cleanup so the declined job stays visible in activity.
    unfinishedAlbum.succeed(
        "systemctl stop repairr.service",
        "rm /run/lidarr-fixture/downloading",
        "touch /run/lidarr-fixture/library-complete /run/pause-lidarr-repairs",
        "systemctl start repairr.service",
    )
    declined = wait_for_json(unfinishedAlbum, job, '.reasonCode == "no_repair_needed"')
    assert_planner_stop(declined, "no_repair_needed", "There are no missing tracks to import.")
    assert "findings" not in declined and "inspectionError" not in declined, declined
    assert not declined["actions"]["answer"] and "question" not in declined, declined
    assert read_job(unfinishedAlbum, f"{REPAIRR}/api/jobs?service=lidarr&view=inbox") == []
    assert submitted_imports(unfinishedAlbum) == []

with subtest("Lidarr rechecks the download even when the prepared tracks have identical bytes"):
    reviewed = read_job(unfinishedAlbum, job)
    track = "/var/lib/repairr-pipeline/Example.Album/01.flac"
    replacement = replace_file(unfinishedAlbum, track)
    assert (
        unfinishedAlbum.succeed(action_request(job + "/remove", reviewed["csrfToken"], reviewed))
        == "204"
    )
    assert find_job(unfinishedAlbum, "lidarr", "Example Album", view="inbox") == job
    fresh = read_job(unfinishedAlbum, job)
    assert (
        fresh["pendingAction"] == "confirm_removal"
        and fresh["fingerprint"] != reviewed["fingerprint"]
    )
    assert unfinishedAlbum.succeed(f"stat -c '%i %s %Y' {track}").split() == replacement
