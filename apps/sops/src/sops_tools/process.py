from __future__ import annotations

import os
import subprocess
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
