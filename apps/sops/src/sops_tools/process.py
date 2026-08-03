from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from typing import Mapping, Protocol, Sequence

from .errors import CommandError


class ProcessRunner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        input_text: str | None = None,
        capture_output: bool = True,
    ) -> str: ...

    def run_streaming(self, argv: Sequence[str]) -> str: ...


@dataclass(frozen=True)
class SubprocessRunner:
    environment: Mapping[str, str] | None = None

    def run(
        self,
        argv: Sequence[str],
        *,
        input_text: str | None = None,
        capture_output: bool = True,
    ) -> str:
        environment = None
        if self.environment is not None:
            environment = {**os.environ, **self.environment}
        completed = subprocess.run(
            list(argv),
            check=False,
            env=environment,
            input=input_text,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None,
            text=True,
        )
        if completed.returncode != 0:
            raise CommandError(argv, completed.returncode, completed.stderr or "")
        return completed.stdout or ""

    def run_streaming(self, argv: Sequence[str]) -> str:
        environment = None
        if self.environment is not None:
            environment = {**os.environ, **self.environment}
        process = subprocess.Popen(
            list(argv),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if process.stdout is None:
            raise CommandError(argv, 1, "Unable to capture command output.")
        lines: list[str] = []
        for line in process.stdout:
            lines.append(line)
            sys.stderr.write(line)
            sys.stderr.flush()
        returncode = process.wait()
        output = "".join(lines)
        if returncode != 0:
            raise CommandError(argv, returncode, output)
        return output
