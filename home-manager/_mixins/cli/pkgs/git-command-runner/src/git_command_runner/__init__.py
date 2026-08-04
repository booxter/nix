import os
import signal
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
    timeout_seconds: float = 120.0
    termination_grace_seconds: float = 2.0

    def run(
        self,
        arguments: Sequence[str],
        *,
        repository: Path | None = None,
    ) -> GitResult:
        command = [self.executable]
        if repository is not None:
            command.extend(["-C", str(repository)])
        process = subprocess.Popen(
            [*command, *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            env=self.environment,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=self.timeout_seconds)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                stdout, stderr = process.communicate(timeout=self.termination_grace_seconds)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout, stderr = process.communicate()
            timeout_message = f"git command timed out after {self.timeout_seconds:g} seconds"
            stderr = f"{stderr.rstrip()}\n{timeout_message}\n" if stderr else f"{timeout_message}\n"
            return GitResult(124, stdout, stderr)
        assert process.returncode is not None
        return GitResult(process.returncode, stdout, stderr)


def stderr_suffix(result: GitResult) -> str:
    message = result.stderr.strip()
    return f": {message}" if message else ""
