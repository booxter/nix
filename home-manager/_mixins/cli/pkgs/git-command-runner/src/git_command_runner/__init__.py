import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class GitResult:
    returncode: int
    stdout: str
    stderr: str


class GitRunner(Protocol):
    def run(
        self,
        arguments: Sequence[str],
        *,
        repository: Path | None = None,
    ) -> GitResult:
        """Run Git and capture its result."""


@dataclass(frozen=True)
class SubprocessGitRunner:
    executable: str = "git"
    environment: Mapping[str, str] | None = None

    def run(
        self,
        arguments: Sequence[str],
        *,
        repository: Path | None = None,
    ) -> GitResult:
        command = [self.executable]
        if repository is not None:
            command.extend(["-C", str(repository)])
        completed = subprocess.run(
            [*command, *arguments],
            check=False,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            env=self.environment,
        )
        return GitResult(completed.returncode, completed.stdout, completed.stderr)


def stderr_suffix(result: GitResult) -> str:
    message = result.stderr.strip()
    return f": {message}" if message else ""
