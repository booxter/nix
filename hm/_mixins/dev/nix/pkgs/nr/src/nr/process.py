import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


class CommandRunner(Protocol):
    def run(
        self, arguments: Sequence[str], *, cwd: Path | None = None, input: str = ""
    ) -> subprocess.CompletedProcess[str]: ...


@dataclass(frozen=True)
class ProcessRunner:
    environment: Mapping[str, str] | None = None

    def run(
        self, arguments: Sequence[str], *, cwd: Path | None = None, input: str = ""
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            arguments,
            cwd=cwd,
            input=input,
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )


def checked(result: subprocess.CompletedProcess[str]) -> str:
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"Command failed with exit {result.returncode}")
    return result.stdout.strip()
