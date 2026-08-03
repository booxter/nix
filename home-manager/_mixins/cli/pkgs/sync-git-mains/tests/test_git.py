from collections import deque
from collections.abc import Sequence
from pathlib import Path

from sync_git_mains.git import GitResult, RepositorySynchronizer


class FakeGitRunner:
    def __init__(self, results: Sequence[GitResult]) -> None:
        self._results = deque(results)
        self.calls: list[tuple[Path, tuple[str, ...]]] = []

    def run(self, repository: Path, arguments: Sequence[str]) -> GitResult:
        self.calls.append((repository, tuple(arguments)))
        return self._results.popleft()


def test_uses_remote_default_branch_when_tracking_symbolic_ref_is_missing() -> None:
    oid = "a" * 40
    git = FakeGitRunner(
        [
            GitResult(0, "https://example.test/repository\n", ""),
            GitResult(1, "", ""),
            GitResult(0, f"ref: refs/heads/master\tHEAD\n{oid}\tHEAD\n", ""),
            GitResult(0, f"{oid}\n", ""),
            GitResult(0, "", ""),
            GitResult(0, f"{oid}\n", ""),
        ]
    )

    result = RepositorySynchronizer(git).sync(Path("/repository"))

    assert result is None
    assert git.calls[4][1] == (
        "fetch",
        "--no-auto-maintenance",
        "--quiet",
        "--prune",
        "origin",
        "master",
    )
