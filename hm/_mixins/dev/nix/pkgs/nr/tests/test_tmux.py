import json
import subprocess
import time
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from nr.process import ProcessRunner
from nr.review import ReviewRequest
from nr.tmux import Submission, TmuxLauncher


def wait_until(predicate: Callable[[], bool]) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    pytest.fail("Timed out waiting for review")


def submit(runner: ProcessRunner, helper: Path, request: ReviewRequest) -> Submission:
    result = runner.run([str(helper)], input=request.model_dump_json())
    assert result.returncode == 0, result.stderr
    return Submission.model_validate_json(result.stdout)


def pane_dead(runner: ProcessRunner, target: str) -> bool:
    result = runner.run(["tmux", "display-message", "-p", "-t", target, "#{pane_dead}"])
    return result.returncode == 0 and result.stdout.strip() == "1"


@pytest.mark.parametrize("status", [0, 7])
def test_job_outlives_submitter_and_retains_result(
    tmux_environment: dict[str, str], helpers: Path, checkout: Path, status: int
) -> None:
    gate = helpers / "finish"
    environment = tmux_environment | {
        "NR_REVIEW_DIRECTORY": str(checkout),
        "NR_TEST_STATUS": str(status),
        "NR_TEST_GATE": str(gate),
        "NR_BUILDERS": "ssh://destination aarch64-linux - 2",
    }
    runner = ProcessRunner(environment)
    submission = submit(runner, helpers / "nr-submit", ReviewRequest(pull_requests=("123",)))
    target = f"nr:{submission.window}"
    report_path = Path(environment["NR_TEST_REPORT"])
    wait_until(report_path.exists)

    assert not pane_dead(runner, target)
    report = json.loads(report_path.read_text())
    assert report["directory"] == str(checkout)
    assert "aarch64-linux" in report["systems"]
    assert report["builders"] == environment["NR_BUILDERS"]

    gate.touch()
    wait_until(lambda: pane_dead(runner, target))
    output = runner.run(["tmux", "capture-pane", "-p", "-t", target]).stdout
    assert "review finished" in output
    assert f"nr: review finished (exit {status})" in output
    result = runner.run(["tmux", "display-message", "-p", "-t", target, "#{pane_dead_status}"])
    assert result.stdout.strip() == str(status)


def test_simultaneous_submissions_share_one_session_with_distinct_windows(
    tmux_environment: dict[str, str], helpers: Path, checkout: Path
) -> None:
    runner = ProcessRunner(tmux_environment | {"NR_REVIEW_DIRECTORY": str(checkout)})
    request = ReviewRequest(pull_requests=("123", "124"))
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(submit, runner, helpers / "nr-submit", request) for _ in range(4)]
        submissions = [future.result() for future in futures]

    assert len({submission.window for submission in submissions}) == 4
    for submission in submissions:
        wait_until(lambda submission=submission: pane_dead(runner, f"nr:{submission.window}"))
    sessions = runner.run(["tmux", "list-sessions", "-F", "#{session_name}"])
    assert sessions.stdout.splitlines() == ["nr"]
    windows = runner.run(["tmux", "list-windows", "-t", "nr", "-F", "#{window_name}"])
    assert set(windows.stdout.splitlines()) == {submission.window for submission in submissions}


@pytest.mark.parametrize("exists", [False, True])
def test_invalid_checkout_is_rejected_before_creating_a_session(
    tmux_environment: dict[str, str], helpers: Path, exists: bool
) -> None:
    checkout = helpers if exists else helpers / "missing"
    runner = ProcessRunner(tmux_environment | {"NR_REVIEW_DIRECTORY": str(checkout)})
    result = runner.run(
        [str(helpers / "nr-submit")], input=ReviewRequest(pull_requests=("123",)).model_dump_json()
    )

    assert result.returncode == 1
    assert str(checkout) in result.stderr
    assert runner.run(["tmux", "has-session", "-t", "=nr"]).returncode != 0


@pytest.mark.parametrize("payload", ["not json", "{}", '{"pull_requests": ["--approve-pr"]}'])
def test_malformed_request_is_rejected(
    tmux_environment: dict[str, str], helpers: Path, payload: str
) -> None:
    result = ProcessRunner(tmux_environment).run([str(helpers / "nr-submit")], input=payload)

    assert result.returncode == 1
    assert "nr:" in result.stderr


class BrokenTmux:
    def run(
        self, arguments: Sequence[str], *, cwd: Path | None = None, input: str = ""
    ) -> subprocess.CompletedProcess[str]:
        if arguments[0] == "git":
            return subprocess.CompletedProcess(arguments, 0, "", "")
        return subprocess.CompletedProcess(arguments, 1, "", "cannot start tmux")


def test_tmux_failure_is_reported(checkout: Path) -> None:
    with pytest.raises(RuntimeError, match="cannot start tmux"):
        TmuxLauncher(BrokenTmux(), checkout, ("nr-worker",)).submit(
            ReviewRequest(pull_requests=("123",))
        )


def test_worker_requires_tmux(review_environment: dict[str, str], helpers: Path) -> None:
    environment = dict(review_environment)
    environment.pop("TMUX_PANE", None)
    result = ProcessRunner(environment).run([str(helpers / "nr-worker"), "{}"])

    assert result.returncode == 1
    assert "must run inside tmux" in result.stderr
