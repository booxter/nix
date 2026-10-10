import json
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

import pytest
from nr.cli import main
from nr.process import ProcessRunner
from nr.remote import SshSubmitter
from nr.review import ReviewRequest
from nr.tmux import Submission
from test_nr import RecordingReviewExecutor
from test_tmux import pane_dead, wait_until


class RecordingSubmitter:
    def __init__(self, error: Exception | None = None) -> None:
        self.host: str | None = None
        self.request: ReviewRequest | None = None
        self.error = error

    def submit(self, host: str, request: ReviewRequest) -> Submission:
        self.host = host
        self.request = request
        if self.error:
            raise self.error
        return Submission(window="pr-123-12345678")


@pytest.mark.parametrize("host", [None, "other"])
def test_remote_submission_preserves_choices_without_resolving_client_defaults(
    capsys: pytest.CaptureFixture[str], host: str | None
) -> None:
    submitter = RecordingSubmitter()
    executor = RecordingReviewExecutor()
    arguments = ["-r", "-l", "-C", "-t", "-p", "-a", "-i", "122", "123", "124"]
    if host:
        arguments.extend(["--host", host])
    result = main(
        arguments,
        environment={"NR_REMOTE_HOST": "frame", "NR_LOCAL_BUILDERS": "laptop-only"},
        executor=executor,
        submitter=submitter,
    )

    assert result == 0
    assert executor.options is None
    assert submitter.host == (host or "frame")
    assert submitter.request == ReviewRequest(
        pull_requests=("123", "124"),
        included_pull_requests=("122",),
        local=True,
        cuda=True,
        tests=True,
        post_result=True,
        approve=True,
    )
    output = capsys.readouterr().out
    assert f"ssh -t {host or 'frame'} tmux attach -t nr" in output
    assert "pr-123-12345678" in output


def test_explicit_remote_systems_are_preserved() -> None:
    submitter = RecordingSubmitter()
    assert main(["-r", "-s", "x86_64-linux", "123"], environment={}, submitter=submitter) == 0
    assert submitter.request is not None
    assert submitter.request.systems == "x86_64-linux"


def test_host_requires_remote() -> None:
    with pytest.raises(SystemExit) as error:
        main(["--host", "frame", "123"])
    assert error.value.code == 2


def test_explicit_empty_host_does_not_fall_back_to_default() -> None:
    submitter = RecordingSubmitter()
    assert main(["-r", "--host", "", "123"], submitter=submitter) == 1
    assert submitter.request is None


@pytest.mark.parametrize("host", ["-oProxyCommand=bad", "frame;bad", "", "frame\nother"])
def test_invalid_host_is_rejected_without_submitting(host: str) -> None:
    submitter = RecordingSubmitter()
    result = main(["-r", "123"], environment={"NR_REMOTE_HOST": host}, submitter=submitter)

    assert result == 1
    assert submitter.request is None


def test_submission_failure_is_reported(capsys: pytest.CaptureFixture[str]) -> None:
    submitter = RecordingSubmitter(RuntimeError("cannot connect"))
    assert main(["-r", "123"], submitter=submitter) == 1
    output = capsys.readouterr()
    assert "cannot connect" in output.err
    assert not output.out


class ReplyTransport:
    def __init__(self, status: int, output: str, error: str = "") -> None:
        self.status = status
        self.output = output
        self.error = error
        self.requests: list[ReviewRequest] = []

    def run(
        self, arguments: Sequence[str], *, cwd: Path | None = None, input: str = ""
    ) -> subprocess.CompletedProcess[str]:
        self.requests.append(ReviewRequest.model_validate_json(input))
        return subprocess.CompletedProcess(arguments, self.status, self.output, self.error)


@pytest.mark.parametrize(
    ("status", "output", "error"),
    [
        (255, "", "connection lost"),
        (1, "", "nr-submit: command not found"),
        (255, "", ""),
        (0, "unexpected output", ""),
        (0, '{"window":"unsafe\\nname"}', ""),
    ],
)
def test_failed_or_lost_acknowledgement_is_not_retried(
    status: int, output: str, error: str
) -> None:
    transport = ReplyTransport(status, output, error)
    with pytest.raises(RuntimeError, match="Check before retrying"):
        SshSubmitter(transport).submit("frame", ReviewRequest(pull_requests=("123",)))

    assert len(transport.requests) == 1


def test_transport_round_trip_preserves_literal_arguments() -> None:
    request = ReviewRequest(pull_requests=("123; echo 'literal'",), systems="x86_64-linux")
    transport = ReplyTransport(0, '{"window":"pr-123-12345678"}')
    result = SshSubmitter(transport).submit("frame", request)

    assert result.window == "pr-123-12345678"
    assert transport.requests == [request]


class InterruptedSubmitter:
    def submit(self, host: str, request: ReviewRequest) -> Submission:
        raise KeyboardInterrupt


def test_interrupted_submission_warns_about_uncertain_status(
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert main(["-r", "123"], submitter=InterruptedSubmitter()) == 130
    assert "check before retrying" in capsys.readouterr().err


def test_cli_to_remote_worker_with_destination_defaults(
    tmux_environment: dict[str, str], helpers: Path, checkout: Path
) -> None:
    # Stand in for the SSH connection, but exercise the actual CLI, JSON
    # receiver, tmux server, worker and review process on the other side.
    ssh = helpers / "ssh"
    ssh.write_text(
        f"#!{sys.executable}\n"
        "import os, subprocess, sys\n"
        "environment = dict(os.environ, NR_BUILDERS='ssh://destination aarch64-linux - 2')\n"
        "result = subprocess.run(['nr-submit'], env=environment, check=False)\n"
        "sys.exit(result.returncode)\n"
    )
    ssh.chmod(0o755)
    environment = tmux_environment | {
        "NR_BUILDERS": "ssh://laptop x86_64-linux /laptop/key 2",
        "NR_REVIEW_DIRECTORY": str(checkout),
    }
    runner = ProcessRunner(environment)
    result = runner.run(
        [sys.executable, "-c", "from nr.cli import main; raise SystemExit(main())", "-r", "123"]
    )
    assert result.returncode == 0, result.stderr
    assert "Submitted to frame" in result.stdout
    wait_until(lambda: pane_dead(runner, "nr:"))
    report = json.loads(Path(environment["NR_TEST_REPORT"]).read_text())
    assert report["builders"] == "ssh://destination aarch64-linux - 2"
    assert "aarch64-linux" in report["systems"]
