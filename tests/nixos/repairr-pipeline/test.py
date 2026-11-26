# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.
import json

COMPLETED_QUEUE_ID = 101
UNFINISHED_QUEUE_ID = 102


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
