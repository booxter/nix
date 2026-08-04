from collections.abc import Sequence
from pathlib import Path

from git_command_runner import GitResult, GitRunner, SubprocessGitRunner, stderr_suffix


class SyncFailure(Exception):
    """A repository cannot be updated safely."""


class RepositorySynchronizer:
    def __init__(self, git: GitRunner | None = None) -> None:
        self._git = git or SubprocessGitRunner()

    def _run(self, path: Path, arguments: Sequence[str]) -> GitResult:
        return self._git.run(arguments, repository=path)

    def _default_branch(self, path: Path) -> str | None:
        symbolic = self._run(
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

        remote = self._run(path, ["ls-remote", "--symref", "origin", "HEAD"])
        if remote.returncode != 0:
            raise SyncFailure(
                f"failed to determine origin's default branch: {path}{stderr_suffix(remote)}"
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
        result = self._run(path, ["worktree", "list", "--porcelain", "-z"])
        if result.returncode != 0:
            raise SyncFailure(f"cannot inspect worktrees for {path}{stderr_suffix(result)}")

        worktree: Path | None = None
        for field in result.stdout.split("\0"):
            if field.startswith("worktree "):
                worktree = Path(field.removeprefix("worktree "))
            elif field == f"branch {local_ref}" and worktree is not None:
                return worktree
        return None

    def sync(self, path: Path) -> str | None:
        origin = self._run(path, ["remote", "get-url", "origin"])
        if origin.returncode != 0:
            return None

        branch = self._default_branch(path)
        if branch is None:
            return None
        local_ref = f"refs/heads/{branch}"
        remote_ref = f"refs/remotes/origin/{branch}"

        local = self._run(path, ["rev-parse", "--verify", local_ref])
        if local.returncode != 0:
            return None
        local_oid = local.stdout.strip()

        fetched = self._run(
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
            raise SyncFailure(f"fetch from origin failed: {path}{stderr_suffix(fetched)}")

        remote = self._run(path, ["rev-parse", "--verify", remote_ref])
        if remote.returncode != 0:
            raise SyncFailure(f"origin/{branch} was not fetched: {path}{stderr_suffix(remote)}")
        remote_oid = remote.stdout.strip()

        if local_oid == remote_oid:
            return None
        ancestor = self._run(
            path,
            ["merge-base", "--is-ancestor", local_oid, remote_oid],
        )
        if ancestor.returncode != 0:
            raise SyncFailure(f"{branch} cannot be fast-forwarded to origin/{branch} in {path}")

        worktree = self._checked_out_worktree(path, local_ref)
        if worktree is not None:
            status = self._run(worktree, ["status", "--porcelain=v1", "-z"])
            if status.returncode != 0:
                raise SyncFailure(f"cannot inspect worktree {worktree}{stderr_suffix(status)}")
            if status.stdout:
                raise SyncFailure(
                    f"{branch} is checked out with a dirty worktree; not updating {path}"
                )
            advanced = self._run(worktree, ["merge", "--ff-only", "--quiet", remote_ref])
            if advanced.returncode != 0:
                raise SyncFailure(
                    f"fast-forward failed in worktree {worktree}{stderr_suffix(advanced)}"
                )
        else:
            advanced = self._run(
                path,
                ["update-ref", local_ref, remote_oid, local_oid],
            )
            if advanced.returncode != 0:
                raise SyncFailure(
                    f"{branch} changed while it was being updated in {path}{stderr_suffix(advanced)}"
                )
        return branch
