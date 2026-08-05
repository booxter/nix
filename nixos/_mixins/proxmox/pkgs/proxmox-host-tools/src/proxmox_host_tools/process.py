from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class Result:
    returncode: int
    stdout: str
    stderr: str


class Runner(Protocol):
    def run(self, command: Sequence[str]) -> Result: ...


@dataclass(frozen=True)
class SubprocessRunner:
    environment: Mapping[str, str] | None = None

    def run(self, command: Sequence[str]) -> Result:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            env=os.environ if self.environment is None else self.environment,
        )
        return Result(completed.returncode, completed.stdout, completed.stderr)
