import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


class SyncFailure(Exception):
    """A repository cannot be updated safely."""


@dataclass(frozen=True)
class GitResult:
    returncode: int
    stdout: str
    stderr: str


class GitRunner(Protocol):
    def run(self, repository: Path, arguments: Sequence[str]) -> GitResult:
        """Run Git in a repository and capture its result."""


@dataclass(frozen=True)
class SubprocessGitRunner:
    executable: str = "git"

    def run(self, repository: Path, arguments: Sequence[str]) -> GitResult:
        completed = subprocess.run(
            [self.executable, "-C", str(repository), *arguments],
            check=False,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
        )
        return GitResult(completed.returncode, completed.stdout, completed.stderr)


def _detail(result: GitResult) -> str:
    message = result.stderr.strip()
    return f": {message}" if message else ""


class RepositorySynchronizer:
    def __init__(self, git: GitRunner | None = None) -> None:
        self._git = git or SubprocessGitRunner()

    def _default_branch(self, path: Path) -> str | None:
        symbolic = self._git.run(
            path,
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
        )
        if symbolic.returncode == 0:
            target = symbolic.stdout.strip()
            if target == "origin/main":
                return "main"
            if target == "origin/master":
                return "master"
            return None

        remote = self._git.run(path, ["ls-remote", "--symref", "origin", "HEAD"])
        if remote.returncode != 0:
            raise SyncFailure(
                f"failed to determine origin's default branch: {path}{_detail(remote)}"
            )
        for line in remote.stdout.splitlines():
            fields = line.split()
            if len(fields) != 3 or fields[0] != "ref:" or fields[2] != "HEAD":
                continue
            if fields[1] == "refs/heads/main":
                return "main"
            if fields[1] == "refs/heads/master":
                return "master"
        return None

    def _checked_out_worktree(self, path: Path, local_ref: str) -> Path | None:
        result = self._git.run(path, ["worktree", "list", "--porcelain", "-z"])
        if result.returncode != 0:
            raise SyncFailure(f"cannot inspect worktrees for {path}{_detail(result)}")

        worktree: Path | None = None
        for field in result.stdout.split("\0"):
            if field.startswith("worktree "):
                worktree = Path(field.removeprefix("worktree "))
            elif field == f"branch {local_ref}" and worktree is not None:
                return worktree
        return None

    def sync(self, path: Path) -> str | None:
        origin = self._git.run(path, ["remote", "get-url", "origin"])
        if origin.returncode != 0:
            return None

        branch = self._default_branch(path)
        if branch is None:
            return None
        local_ref = f"refs/heads/{branch}"
        remote_ref = f"refs/remotes/origin/{branch}"

        local = self._git.run(path, ["rev-parse", "--verify", local_ref])
        if local.returncode != 0:
            return None
        local_oid = local.stdout.strip()

        fetched = self._git.run(
            path,
            [
                "fetch",
                "--no-auto-maintenance",
                "--quiet",
                "--prune",
                "origin",
                branch,
            ],
        )
        if fetched.returncode != 0:
            raise SyncFailure(f"fetch from origin failed: {path}{_detail(fetched)}")

        remote = self._git.run(path, ["rev-parse", "--verify", remote_ref])
        if remote.returncode != 0:
            raise SyncFailure(f"origin/{branch} was not fetched: {path}{_detail(remote)}")
        remote_oid = remote.stdout.strip()

        if local_oid == remote_oid:
            return None
        ancestor = self._git.run(
            path,
            ["merge-base", "--is-ancestor", local_oid, remote_oid],
        )
        if ancestor.returncode != 0:
            raise SyncFailure(f"{branch} cannot be fast-forwarded to origin/{branch} in {path}")

        worktree = self._checked_out_worktree(path, local_ref)
        if worktree is not None:
            status = self._git.run(worktree, ["status", "--porcelain=v1", "-z"])
            if status.returncode != 0:
                raise SyncFailure(f"cannot inspect worktree {worktree}{_detail(status)}")
            if status.stdout:
                raise SyncFailure(
                    f"{branch} is checked out with a dirty worktree; not updating {path}"
                )
            advanced = self._git.run(worktree, ["merge", "--ff-only", "--quiet", remote_ref])
            if advanced.returncode != 0:
                raise SyncFailure(f"fast-forward failed in worktree {worktree}{_detail(advanced)}")
        else:
            advanced = self._git.run(
                path,
                ["update-ref", local_ref, remote_oid, local_oid],
            )
            if advanced.returncode != 0:
                raise SyncFailure(
                    f"{branch} changed while it was being updated in {path}{_detail(advanced)}"
                )
        return branch
