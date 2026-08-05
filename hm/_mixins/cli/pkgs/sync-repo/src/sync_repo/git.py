from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from git_command_runner import GitResult, GitRunner, SubprocessGitRunner, stderr_suffix


@dataclass(frozen=True)
class RepositorySpec:
    name: str
    remote: str
    path: Path


class SyncOutcome(StrEnum):
    CLONED = "cloned"
    PUSHED = "pushed"
    UP_TO_DATE = "up-to-date"


class SyncError(Exception):
    """A personal repository could not be synchronized safely."""


class RebaseFailed(SyncError):
    """A rebase stopped for manual conflict resolution."""


def repository_specs(
    home: Path,
    environ: Mapping[str, str],
) -> dict[str, RepositorySpec]:
    xdg_data = Path(environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    password_store = Path(environ.get("PASSWORD_STORE_DIR", xdg_data / "password-store"))
    return {
        "gmailctl": RepositorySpec(
            "gmailctl",
            "git@github.com:booxter/gmailctl-private-config.git",
            home / ".gmailctl",
        ),
        "pass": RepositorySpec(
            "pass",
            "git@github.com:booxter/pass.git",
            password_store,
        ),
        "dotfiles": RepositorySpec(
            "dotfiles",
            "git@github.com:booxter/dotfiles.git",
            home / ".priv-bin",
        ),
    }


def _divergence(result: GitResult, upstream: str) -> tuple[int, int]:
    if result.returncode != 0:
        raise SyncError(f"cannot compare local branch with {upstream}{stderr_suffix(result)}")
    fields = result.stdout.split()
    if len(fields) != 2:
        raise SyncError(f"cannot parse divergence from {upstream}: {result.stdout.strip()}")
    try:
        return int(fields[0]), int(fields[1])
    except ValueError as error:
        raise SyncError(
            f"cannot parse divergence from {upstream}: {result.stdout.strip()}"
        ) from error


class RepositorySynchronizer:
    def __init__(self, git: GitRunner | None = None) -> None:
        self._git = git or SubprocessGitRunner()

    def _run(self, path: Path, arguments: Sequence[str]) -> GitResult:
        return self._git.run(arguments, repository=path)

    def _upstream(self, path: Path, branch: str) -> str | None:
        result = self._run(
            path,
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
        )
        if result.returncode == 0:
            return result.stdout.strip()

        upstream = f"origin/{branch}"
        origin_ref = self._run(
            path,
            ["show-ref", "--verify", "--quiet", f"refs/remotes/{upstream}"],
        )
        if origin_ref.returncode != 0:
            return None
        configured = self._run(
            path,
            ["branch", "--set-upstream-to", upstream, branch],
        )
        if configured.returncode != 0:
            raise SyncError(f"cannot set upstream to {upstream}{stderr_suffix(configured)}")
        return upstream

    def _push_new_branch(self, path: Path, branch: str) -> None:
        pushed = self._run(path, ["push", "--quiet", "--set-upstream", "origin", branch])
        if pushed.returncode != 0:
            raise SyncError(f"push failed{stderr_suffix(pushed)}")

    def _compare(self, path: Path, upstream: str) -> tuple[int, int]:
        result = self._run(
            path,
            ["rev-list", "--left-right", "--count", f"HEAD...{upstream}"],
        )
        return _divergence(result, upstream)

    def sync(self, spec: RepositorySpec) -> SyncOutcome:
        if not spec.path.exists():
            spec.path.parent.mkdir(parents=True, exist_ok=True)
            cloned = self._git.run(["clone", "--quiet", spec.remote, str(spec.path)])
            if cloned.returncode != 0:
                raise SyncError(f"clone failed{stderr_suffix(cloned)}")
            return SyncOutcome.CLONED

        repository = self._run(spec.path, ["rev-parse", "--git-dir"])
        if repository.returncode != 0:
            raise SyncError(f"{spec.name} is not a Git repository: {spec.path}")

        head = self._run(spec.path, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        if head.returncode != 0:
            raise SyncError(f"detached HEAD in {spec.path}; fix it manually")
        branch = head.stdout.strip()

        fetched = self._run(
            spec.path,
            ["fetch", "--no-auto-maintenance", "--quiet", "--prune", "origin"],
        )
        if fetched.returncode != 0:
            raise SyncError(f"fetch from origin failed{stderr_suffix(fetched)}")

        upstream = self._upstream(spec.path, branch)
        if upstream is None:
            self._push_new_branch(spec.path, branch)
            return SyncOutcome.PUSHED

        ahead, behind = self._compare(spec.path, upstream)
        if behind > 0:
            rebased = self._run(spec.path, ["rebase", upstream])
            if rebased.returncode != 0:
                raise RebaseFailed(f"rebase failed in {spec.path}; resolve it there manually")
            ahead, behind = self._compare(spec.path, upstream)

        if behind > 0:
            raise SyncError("local branch still diverges from its upstream after rebase")
        if ahead == 0:
            return SyncOutcome.UP_TO_DATE

        pushed = self._run(spec.path, ["push", "--quiet"])
        if pushed.returncode != 0:
            raise SyncError(f"push failed{stderr_suffix(pushed)}")
        return SyncOutcome.PUSHED
