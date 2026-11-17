import io
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
from claude_worktree import GitCli, run


def git(cwd: Path, *arguments: str) -> str:
    identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]
    completed = subprocess.run(
        ["git", *identity, *arguments], cwd=cwd, capture_output=True, text=True, check=True
    )
    return completed.stdout.strip()


@dataclass(frozen=True)
class Result:
    code: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class Hook:
    root: Path

    def __call__(self, *arguments: str, payload: object = None) -> Result:
        stdout = io.StringIO()
        stderr = io.StringIO()
        code = run(
            list(arguments),
            io.StringIO(json.dumps(payload)),
            stdout,
            stderr,
            self.root,
            GitCli(),
        )
        return Result(code, stdout.getvalue(), stderr.getvalue())

    def create(self, cwd: Path, name: str) -> Path:
        result = self("create", payload={"cwd": str(cwd), "name": name})
        assert result.code == 0, result.stderr
        return Path(result.stdout.removesuffix("\n"))


@pytest.fixture
def repository(tmp_path: Path) -> Path:
    path = tmp_path / "nix"
    path.mkdir()
    git(path, "init", "--quiet", "--initial-branch=master")
    git(path, "commit", "--quiet", "--allow-empty", "--message=first")
    return path


@pytest.fixture
def hook(tmp_path: Path) -> Hook:
    return Hook(tmp_path / "worktrees")


def test_create_checks_out_new_named_branch_from_current_head(repository: Path, hook: Hook) -> None:
    git(repository, "switch", "--quiet", "--create", "feature")
    git(repository, "commit", "--quiet", "--allow-empty", "--message=feature work")

    path = hook.create(repository, "fix/retries")

    assert path == hook.root / "nix" / "fix" / "retries"
    assert git(path, "branch", "--show-current") == "fix/retries"
    assert git(path, "rev-parse", "HEAD") == git(repository, "rev-parse", "feature")


def test_create_checks_out_existing_branch(repository: Path, hook: Hook) -> None:
    git(repository, "branch", "existing")
    git(repository, "commit", "--quiet", "--allow-empty", "--message=newer")

    path = hook.create(repository, "existing")

    assert git(path, "rev-parse", "HEAD") == git(repository, "rev-parse", "existing")


def test_reusing_a_name_reopens_the_worktree_from_any_checkout(
    repository: Path, hook: Hook
) -> None:
    path = hook.create(repository, "topic")
    (path / "work.txt").write_text("in progress\n")

    assert hook.create(path, "topic") == path
    assert (path / "work.txt").read_text() == "in progress\n"


def test_remove_keeps_the_branch(repository: Path, hook: Hook) -> None:
    path = hook.create(repository, "topic")

    result = hook("remove", payload={"worktree_path": str(path)})

    assert result.code == 0, result.stderr
    assert not path.exists()
    assert git(repository, "branch", "--list", "topic") != ""


def test_remove_refuses_uncommitted_work(repository: Path, hook: Hook) -> None:
    path = hook.create(repository, "topic")
    (path / "work.txt").write_text("unsaved\n")

    result = hook("remove", payload={"worktree_path": str(path)})

    assert result.code == 1
    assert "untracked" in result.stderr
    assert (path / "work.txt").exists()


def test_failures_go_to_stderr(tmp_path: Path, hook: Hook) -> None:
    outside = hook("create", payload={"cwd": str(tmp_path), "name": "topic"})
    malformed = hook("create", payload={"name": "topic"})
    usage = hook("prune")

    assert (outside.code, outside.stdout) == (1, "")
    assert "not a git repository" in outside.stderr
    assert (malformed.code, malformed.stdout) == (1, "")
    assert "cwd" in malformed.stderr
    assert usage.code == 2
    assert usage.stderr.startswith("usage:")
