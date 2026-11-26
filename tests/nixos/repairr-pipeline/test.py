# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.
import json
import shlex

COMPLETED_QUEUE_ID = 101
UNFINISHED_QUEUE_ID = 102
VIDEO = "/var/lib/repairr-pipeline/Example.Movie.2026/movie.mkv"
PAUSE = "/run/pause-radarr-repairs"


def collect_queue():
    output = machine.succeed("repairr --collect-radarr --config /etc/repairr.json")
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


def wait_for_movie(vm, state, text):
    page = shlex.quote(f"http://127.0.0.1:8790/activity?service=radarr&state={state}")
    vm.wait_until_succeeds(f"curl -fsS {page} | grep -F -- {shlex.quote(text)}", timeout=60)


def plan_with_repairs_paused(vm):
    vm.wait_for_open_port(7878)
    vm.wait_until_succeeds("test -S /run/repairr-planner/planner.sock")
    vm.succeed(f"touch {PAUSE}", "systemctl start repairr.service")
    wait_for_movie(vm, "ready", "Example Movie")


def submitted_imports(vm):
    return json.loads(vm.succeed("curl -fsS http://127.0.0.1:7878/fixture/imports"))


machine.start()
machine.wait_for_open_port(7878)
reports = collect_queue()

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

with subtest("the saved plan authorizes the selected file for the expected movie and download"):
    plan_with_repairs_paused(machine)
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
