import os
import subprocess
from pathlib import Path

from git_command_runner import GitResult, SubprocessGitRunner, stderr_suffix


def initialize_repository(path: Path) -> None:
    subprocess.run(
        ["git", "init", "--initial-branch=main", str(path)],
        check=True,
        capture_output=True,
        encoding="utf-8",
    )


def test_runs_git_in_repository_and_captures_failures(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    initialize_repository(repository)
    runner = SubprocessGitRunner()

    root = runner.run(["rev-parse", "--show-toplevel"], repository=repository)
    missing = runner.run(
        ["rev-parse", "--verify", "refs/heads/missing"],
        repository=repository,
    )

    assert root.returncode == 0
    assert Path(root.stdout.strip()).resolve() == repository.resolve()
    assert root.stderr == ""
    assert missing.returncode != 0
    assert missing.stderr


def test_runs_without_repository_and_injects_environment() -> None:
    environment = os.environ.copy()
    environment.update(
        {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "test.marker",
            "GIT_CONFIG_VALUE_0": "injected",
        }
    )

    result = SubprocessGitRunner(environment=environment).run(["config", "--get", "test.marker"])

    assert result.returncode == 0
    assert result.stdout == "injected\n"
    assert result.stderr == ""


def test_formats_stderr_as_an_optional_message_suffix() -> None:
    assert stderr_suffix(GitResult(1, "", "failure\n")) == ": failure"
    assert stderr_suffix(GitResult(0, "", "")) == ""
